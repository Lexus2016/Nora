import Darwin
import Foundation
import XCTest
@testable import MoleKit

/// A mounted volume's per-user Trash is a different root from the home Trash, but it uses the
/// same engine and the same rules. These fixtures are ordinary directories; nothing is mounted.
final class TrashVolumeSafetyTests: XCTestCase {
    private final class Fixture {
        let mount: URL
        var trashes: URL { mount.appendingPathComponent(".Trashes", isDirectory: true) }
        var trash: URL { trashes.appendingPathComponent(String(geteuid()), isDirectory: true) }
        var staging: URL { trashes.appendingPathComponent(".NoraTrash-\(geteuid())", isDirectory: true) }

        init() throws {
            // The no-follow root open rejects a symlinked component, so resolve the fixture parent.
            guard let physicalParent = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "Cannot resolve the fixture parent"])
            }
            defer { free(physicalParent) }
            mount = URL(fileURLWithPath: String(cString: physicalParent), isDirectory: true)
                .appendingPathComponent("nora-volume-fixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: mount) }

        func location() -> TrashLocation {
            .volume(mount: mount, owner: UInt32(geteuid()), label: "Fixture Disk")
        }
        func file(_ name: String, _ text: String = "fixture") throws {
            try Data(text.utf8).write(to: trash.appendingPathComponent(name))
        }
        func service(limits: TrashScanLimits = TrashScanLimits()) -> TrashService {
            TrashService(location: location())
        }
    }

    func testVolumeTrashIsReviewedAndEmptiedWithStagingOnTheSameVolume() throws {
        let fixture = try Fixture()
        try fixture.file("clip.mov", "video")
        try fixture.file("draft.txt", "text")
        let service = fixture.service()
        XCTAssertFalse(service.recoveryStatus().blocksNewRun)
        let snapshot = try service.scan()
        XCTAssertEqual(snapshot.entries.map(\.relativePath), ["clip.mov", "draft.txt"])
        XCTAssertEqual(snapshot.topLevelItemCount, 2)
        let result = service.execute(snapshot)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.deletedEntryCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.staging.path),
                      "The staging root stays for the next run")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), [".lock"])
        XCTAssertFalse(service.recoveryStatus().blocksNewRun)
    }

    func testVolumeWithoutATrashIsUnavailableNotEmpty() throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.trash)
        XCTAssertThrowsError(try fixture.service().scan())
    }

    func testSymlinkedVolumeTrashIsRejected() throws {
        let fixture = try Fixture()
        let elsewhere = fixture.mount.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: fixture.trash)
        try FileManager.default.createSymbolicLink(at: fixture.trash, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try fixture.service().scan())
    }

    /// A volume Trash is shared by every user account on that disk; group/other write needs the
    /// sticky bit, exactly as the system sets it on shared volumes.
    func testWorldWritableVolumeTrashNeedsTheStickyBit() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        XCTAssertEqual(chmod(fixture.trash.path, 0o777), 0)
        XCTAssertThrowsError(try fixture.service().scan())
        XCTAssertEqual(chmod(fixture.trash.path, 0o1777), 0)
        XCTAssertEqual(try fixture.service().scan().topLevelItemCount, 1)
    }

    func testStagingMustStayOnTheVolume() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        try FileManager.default.createDirectory(at: fixture.staging, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: fixture.staging)
        let elsewhere = fixture.mount.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.staging, withDestinationURL: elsewhere)
        let service = fixture.service()
        let result = service.execute(try service.scan())
        XCTAssertTrue([.failed, .recoveryRequired].contains(result.status),
                      "Staging reached through a symlink must never be used")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }
}
