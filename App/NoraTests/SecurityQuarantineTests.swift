import XCTest
@testable import Nora

/// Quarantine store against a temp root. No test here unloads a launch agent or touches real files.
final class SecurityQuarantineTests: XCTestCase {
    private var root: URL!
    private var store: QuarantineStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nora-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = QuarantineStore(root: root.appendingPathComponent("Quarantine", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, mode: Int = 0o755) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("abc".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    func testMoveRecordsHashModeAndDetection() throws {
        let file = try makeFile("sample.bin")
        let entry = try store.move(file, detection: "Fixture.Signature")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(entry.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(entry.posixMode, 0o755)
        XCTAssertEqual(entry.detection, "Fixture.Signature")
        XCTAssertEqual(store.list().map(\.id), [entry.id])
    }

    func testMovedFileLosesExecuteBitsUntilRestored() throws {
        let file = try makeFile("runnable.sh")
        let entry = try store.move(file, detection: "Fixture.Signature")
        let stored = root.appendingPathComponent("Quarantine/\(entry.id.uuidString)/payload/runnable.sh")
        XCTAssertEqual(try mode(of: stored), 0o600)
        try store.restore(entry)
        XCTAssertEqual(try mode(of: file), 0o755)
    }

    func testRestoreReturnsFileAndRemovesFolder() throws {
        let file = try makeFile("back.bin")
        let entry = try store.move(file, detection: "Fixture.Signature")
        try store.restore(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testRestoreRefusesToOverwriteAFileAtTheOriginalPath() throws {
        let file = try makeFile("taken.bin")
        let entry = try store.move(file, detection: "Fixture.Signature")
        try Data("new".utf8).write(to: file)
        XCTAssertThrowsError(try store.restore(entry)) { error in
            guard case QuarantineError.targetExists = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(store.list().count, 1)
    }

    func testDeleteRemovesTheEntry() throws {
        let file = try makeFile("gone.bin")
        let entry = try store.move(file, detection: "Fixture.Signature")
        try store.delete(entry)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// X02: a file named meta.json is quarantined and restored like any other.
    func testAFileNamedMetaJSONRoundTrips() throws {
        let file = try makeFile("meta.json")
        let entry = try store.move(file, detection: "Fixture.Signature")
        XCTAssertEqual(store.list().map(\.id), [entry.id])
        try store.restore(entry)
        XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
    }

    /// Entries written before the payload folder keep the file next to meta.json.
    func testOldLayoutIsStillRestored() throws {
        let file = try makeFile("old.bin")
        let entry = try store.move(file, detection: "Fixture.Signature")
        let folder = root.appendingPathComponent("Quarantine/\(entry.id.uuidString)")
        try FileManager.default.moveItem(at: folder.appendingPathComponent("payload/old.bin"), to: folder.appendingPathComponent("old.bin"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("payload"))
        try store.restore(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// S4: a file inside the quarantine is never moved again, which would split its entry.
    func testAQuarantinedFileCannotBeQuarantinedAgain() throws {
        let entry = try store.move(try makeFile("twice.bin"), detection: "Fixture.Signature")
        XCTAssertThrowsError(try store.move(store.storedFile(entry), detection: "Fixture.Signature")) { error in
            guard case QuarantineError.alreadyQuarantined = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(store.list().count, 1)
    }
}
