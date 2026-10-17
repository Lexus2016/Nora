import XCTest
@testable import Nora

/// Every writer is injected. No test reads or writes the user's Mole configuration.
@MainActor
final class ProtectionSaveRegressionTests: XCTestCase {
    private func loadedModel(write: @escaping (URL, String) throws -> Void) async -> ProtectionModel {
        let model = ProtectionModel(write: write)
        let snapshot = ProtectionModel.Snapshot(home: URL(fileURLWithPath: "/fixture/home"),
                                               defaults: ["~/protected"], cleanLines: nil, tasks: [],
                                               optimizeLines: [], purgeLines: nil)
        await model.load { _ in snapshot }?.value
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.cleanupReady)
        return model
    }

    private func failingModel() async -> ProtectionModel {
        await loadedModel(write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    }

    func testFailedCleanupAddAndRemovalPreserveSavedState() async {
        let model = await failingModel()
        model.addPattern("~/new")
        XCTAssertTrue(model.custom.isEmpty)
        XCTAssertFalse(model.cleanFileExists)
        XCTAssertNotNil(model.message)
        model.custom = ["~/existing"]
        model.cleanFileExists = true
        model.removePattern("~/existing")
        XCTAssertEqual(model.custom, ["~/existing"])
        XCTAssertTrue(model.cleanFileExists)
    }

    func testFailedMaintenanceToggleAndBulkEditRestorePriorSelection() async {
        let model = await failingModel()
        model.tasks = [("First", "first"), ("Second", "second")]
        model.excludedTasks = ["first"]
        model.setTask("second", excluded: true)
        XCTAssertEqual(model.excludedTasks, ["first"])
        model.setTask("first", excluded: false)
        XCTAssertEqual(model.excludedTasks, ["first"])
        model.setAllTasks(included: ["first", "second"])
        XCTAssertEqual(model.excludedTasks, ["first"])
    }

    func testFailedProjectEditPreservesPathsAndExistenceFlag() async {
        let model = await failingModel()
        model.addProjectFolder("/fixture/project")
        XCTAssertTrue(model.projectFolders.isEmpty)
        XCTAssertFalse(model.projectFileExists)
        model.projectFolders = ["/fixture/existing"]
        model.projectFileExists = true
        model.removeProjectFolder("/fixture/existing")
        XCTAssertEqual(model.projectFolders, ["/fixture/existing"])
        XCTAssertTrue(model.projectFileExists)
    }

    func testSuccessfulInjectedWriteCommitsAndPreservesDefaults() async {
        var writes: [String] = []
        let model = await loadedModel(write: { _, body in writes.append(body) })
        model.addPattern("~/new")
        XCTAssertEqual(model.custom, ["~/new"])
        XCTAssertTrue(model.cleanFileExists)
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].contains("~/protected\n~/new\n"))
        model.addProjectFolder("/fixture/project")
        XCTAssertEqual(model.projectFolders, ["/fixture/project"])
        XCTAssertTrue(model.projectFileExists)
    }
}
