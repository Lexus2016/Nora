import XCTest
@testable import Nora

/// Every writer is injected. No test reads or writes the user's Mole configuration.
@MainActor
final class ProtectionSaveRegressionTests: XCTestCase {
    private func failingModel() -> ProtectionModel {
        let model = ProtectionModel(write: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertTrue(model.loadDefaults { ["~/protected"] })
        model.loaded = true
        return model
    }

    func testFailedCleanupAddAndRemovalPreserveSavedState() {
        let model = failingModel()
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

    func testFailedMaintenanceToggleAndBulkEditRestorePriorSelection() {
        let model = failingModel()
        model.tasks = [("First", "first"), ("Second", "second")]
        model.excludedTasks = ["first"]
        model.setTask("second", excluded: true)
        XCTAssertEqual(model.excludedTasks, ["first"])
        model.setTask("first", excluded: false)
        XCTAssertEqual(model.excludedTasks, ["first"])
        model.setAllTasks(included: ["first", "second"])
        XCTAssertEqual(model.excludedTasks, ["first"])
    }

    func testFailedProjectEditPreservesPathsAndExistenceFlag() {
        let model = failingModel()
        model.addProjectFolder("/fixture/project")
        XCTAssertTrue(model.projectFolders.isEmpty)
        XCTAssertFalse(model.projectFileExists)
        model.projectFolders = ["/fixture/existing"]
        model.projectFileExists = true
        model.removeProjectFolder("/fixture/existing")
        XCTAssertEqual(model.projectFolders, ["/fixture/existing"])
        XCTAssertTrue(model.projectFileExists)
    }

    func testSuccessfulInjectedWriteCommitsAndPreservesDefaults() {
        var writes: [String] = []
        let model = ProtectionModel(write: { _, body in writes.append(body) })
        XCTAssertTrue(model.loadDefaults { ["~/protected"] })
        model.loaded = true
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
