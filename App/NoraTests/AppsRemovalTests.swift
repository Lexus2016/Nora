import XCTest
import MoleKit
@testable import Nora

/// Only synthetic temporary files. No Mole runs, applications or real Trash are touched.
final class AppsRemovalTests: XCTestCase {
    @MainActor
    func testRemovalAsksOnlyForSelectedRunningAppsAndCancelStartsNothing() throws {
        let app = AppModel(visualSnapshot: true, home: try sandbox())
        let model = app.apps
        let data = Data("""
            [{"name":"One","path":"/synthetic/One.app"},{"name":"Two","path":"/synthetic/Two.app"}]
            """.utf8)
        let apps = try InstalledApp.decodeList(data)
        model.stage = .review
        model.screen = .plans
        model.plans = [.init(app: apps[0], entries: [apps[0].path])]
        model.requestUninstall(app, isOpen: { _ in true })
        XCTAssertTrue(model.askingToQuitForRemoval)
        XCTAssertEqual(model.removalOpenApps.map(\.path), [apps[0].path])
        XCTAssertEqual(model.stage, .review)
        XCTAssertTrue(app.console.entries.isEmpty)
        model.cancelRemovalQuit()
        XCTAssertFalse(model.askingToQuitForRemoval)
        XCTAssertTrue(model.removalOpenApps.isEmpty)
        XCTAssertTrue(app.console.entries.isEmpty)
    }

    @MainActor
    func testAllAppsClearsOldSearchAndUnusedFilterWithoutLosingSelection() throws {
        let data = Data("""
            [{"name":"One","path":"/synthetic/One.app"},{"name":"Two","path":"/synthetic/Two.app"}]
            """.utf8)
        let model = AppsModel()
        model.apps = try InstalledApp.decodeList(data)
        model.search = "One"
        model.listFilter = .unused
        model.unusedPaths = ["/synthetic/One.app"]
        model.selected = ["/synthetic/One.app"]
        model.openList(.all)
        XCTAssertEqual(model.screen, .list)
        XCTAssertEqual(model.listFilter, .all)
        XCTAssertTrue(model.search.isEmpty)
        XCTAssertEqual(Set(model.visible.map(\.name)), ["One", "Two"])
        XCTAssertEqual(model.selected, ["/synthetic/One.app"])
    }

    @MainActor
    func testUninstallCommandUsesAppNameInsteadOfHomebrewToken() throws {
        let data = Data("""
            [{"name":"Vivid","uninstall_name":"vivid-app","source":"Homebrew","path":"/synthetic/Vivid.app"}]
            """.utf8)
        let apps = try InstalledApp.decodeList(data)
        let model = AppsModel()
        let command = model.uninstallCommand(for: apps)
        XCTAssertTrue(command.contains("mo uninstall Vivid"))
        XCTAssertFalse(command.contains("vivid-app"))
    }

    func testRemovalPlanMustIncludeTheSelectedBundlePath() {
        XCTAssertTrue(AppsModel.removalPlanIncludesApp(["/synthetic/Vivid.app", "/synthetic/cache"], path: "/synthetic/Vivid.app"))
        XCTAssertFalse(AppsModel.removalPlanIncludesApp(["/other/Vivid.app", "/synthetic/cache"], path: "/synthetic/Vivid.app"))
    }

    func testHomebrewRemovalRequiresAuthenticationEvenForWritableApp() throws {
        let root = try sandbox()
        let bundle = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            ["name": "Fixture", "source": "Homebrew", "path": bundle.path],
            ["name": "Fixture", "source": "App", "path": bundle.path]
        ])
        let apps = try InstalledApp.decodeList(data)
        XCTAssertTrue(FileManager.default.isDeletableFile(atPath: bundle.path))
        XCTAssertTrue(AppsModel.uninstallNeedsAdmin(apps[0]))
        XCTAssertFalse(AppsModel.uninstallNeedsAdmin(apps[1]))
    }

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
