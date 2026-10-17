import XCTest
@testable import Nora

/// Only synthetic temporary files. No Mole runs, applications or real Trash are touched.
final class AppsRemovalTests: XCTestCase {
    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nora-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testZeroExitWithoutDeletionStillLeavesUnverifiedPaths() throws {
        let root = try sandbox()
        let app = root.appendingPathComponent("Fixture.app")
        let helper = root.appendingPathComponent("helper")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: helper)
        XCTAssertEqual(AppsModel.remainingRemovalPaths(appPath: app.path, entries: [app.path, helper.path]),
                       [app.path, helper.path].sorted())
    }

    func testPartialRemovalReportsRemainingHelper() throws {
        let root = try sandbox()
        let app = root.appendingPathComponent("Fixture.app")
        let helper = root.appendingPathComponent("helper")
        try Data("synthetic".utf8).write(to: helper)
        XCTAssertTrue(AppsModel.removalPathIsAbsent(app.path))
        XCTAssertEqual(AppsModel.remainingRemovalPaths(appPath: app.path, entries: [helper.path]), [helper.path])
    }

    func testMoveToSyntheticTrashVerifiesSourceAbsenceWithoutClaimingDestination() throws {
        let root = try sandbox()
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("SyntheticTrash.app"))
        XCTAssertEqual(AppsModel.remainingRemovalPaths(appPath: app.path, entries: [app.path]), [])
    }

    func testDanglingLinkIsStillPresentAndRelativePathIsUnverified() throws {
        let root = try sandbox()
        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertFalse(AppsModel.removalPathIsAbsent(link.path))
        XCTAssertFalse(AppsModel.removalPathIsAbsent("relative"))
    }

    func testPermissionOrUnknownProbeDoesNotBecomeSuccess() {
        XCTAssertFalse(AppsModel.removalPathIsAbsent("/synthetic/A.app", attributes: { _ in
            throw CocoaError(.fileReadNoPermission)
        }))
        XCTAssertFalse(AppsModel.removalPathIsAbsent("/synthetic/A.app", attributes: { _ in
            throw CocoaError(.fileReadUnknown)
        }))
        XCTAssertTrue(AppsModel.removalPathIsAbsent("/synthetic/A.app", attributes: { _ in
            throw CocoaError(.fileReadNoSuchFile)
        }))
        // A probe that cannot establish absence must return false, including permission errors.
        XCTAssertEqual(AppsModel.remainingRemovalPaths(appPath: "/synthetic/A.app", entries: ["/synthetic/helper"],
                                                       isAbsent: { _ in false }),
                       ["/synthetic/A.app", "/synthetic/helper"])
    }
}
