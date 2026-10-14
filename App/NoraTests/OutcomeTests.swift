import XCTest
import MoleKit
@testable import Nora

/// U01, U03, U04: empty Smart Care steps, History's failed tasks, Tools' failure text.
@MainActor
final class OutcomeTests: XCTestCase {
    func testSmartCareSkipsAModuleWithNothingTicked() {
        let app = AppModel()
        XCTAssertFalse(app.smartCare.hasWork(.projects, app))
        XCTAssertFalse(app.smartCare.hasWork(.installers, app))
        XCTAssertFalse(app.smartCare.hasWork(.cleanup, app))
        app.projects.selected = ["/p/node_modules"]
        XCTAssertTrue(app.smartCare.hasWork(.projects, app))
        XCTAssertTrue(app.smartCare.hasWork(.performance, app))
    }

    func testHistoryCountsFailedMaintenanceTasksApart() throws {
        let json = Data("""
        {"sessions": [{"command": "optimize", "run_id": "a", "items": 0, "operation_count": 3, "failed_tasks": 2,
                       "actions": {"removed": 0, "trashed": 0, "skipped": 0, "failed": 0, "rebuilt": 0}},
                      {"command": "clean", "run_id": "b", "items": 1, "operation_count": 1, "failed_tasks": 0,
                       "actions": {"removed": 1, "trashed": 0, "skipped": 0, "failed": 1, "rebuilt": 0}}]}
        """.utf8)
        let model = HistoryModel()
        model.sessions = try JSONDecoder().decode(MoleHistory.self, from: json).sessions
        XCTAssertEqual(model.actions.failed, 1)
        XCTAssertEqual(model.actions.failedTasks, 2)
    }

    func testToolsNamesTheFailureInsteadOfAnEmptyCard() {
        let failed = ToolsModel.Attempt(result: CommandResult(status: 2, stdout: "", stderr: "Permission denied\n"))
        XCTAssertEqual(ToolsModel.failure(failed, preview: true), String(localized: "The preview failed: \("Permission denied")"))
        XCTAssertNil(ToolsModel.failure(ToolsModel.Attempt(result: CommandResult(status: 0, stdout: "", stderr: "")), preview: true))
        XCTAssertNotNil(ToolsModel.failure(ToolsModel.Attempt(error: NoraError.moleMissing), preview: false))
    }
}
