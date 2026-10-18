import XCTest
import MoleKit
@testable import Nora

/// In-memory command results only; these tests never execute Mole or touch user history.
@MainActor
final class HistoryConsoleRegressionTests: XCTestCase {
    func testMole161PreviewsStayVisibleWithoutInflatingFreedSpaceOrActions() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let today = formatter.string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: ["sessions": [
            ["command": "clean-dry-run", "started_at": today, "size": "8GB", "actions": ["removed": 99, "failed": 5]],
            ["command": "clean", "started_at": today, "size": "2MB", "actions": ["removed": 2]]
        ]])
        let model = HistoryModel()
        model.sessions = try JSONDecoder().decode(MoleHistory.self, from: data).sessions
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.totalFreed, 2_000_000)
        XCTAssertEqual(model.actions.removed, 2)
        XCTAssertEqual(model.actions.failed, 0)
        XCTAssertEqual(model.freedByCommand.count, 1)
        XCTAssertEqual(model.daily.first?.size, 2_000_000)
        XCTAssertEqual(HistoryView.commandTitle("clean-dry-run"), String(localized: "Preview: \(String(localized: "Cleanup"))"))
    }

    func testNonzeroHistoryExitCannotBecomeEmptySuccess() {
        XCTAssertThrowsError(try HistoryModel.decode(CommandResult(status: 1, stdout: "{\"sessions\":[]}", stderr: "permission denied"))) {
            XCTAssertTrue($0.localizedDescription.contains("permission denied"))
        }
        XCTAssertThrowsError(try HistoryModel.decode(CommandResult(status: 2, stdout: "{}", stderr: "")))
    }

    func testEmptyAndPopulatedSuccessfulHistory() throws {
        XCTAssertTrue(try HistoryModel.decode(CommandResult(status: 0, stdout: "{\"sessions\":[]}", stderr: "")).isEmpty)
        let sessions = try HistoryModel.decode(CommandResult(status: 0, stdout: "{\"sessions\":[{\"command\":\"clean\",\"size\":\"2 GB\"}]}", stderr: ""))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.command, "clean")
    }

    func testHistoryLoadOwnsConsoleAndShowsLoadingUntilCompletion() async {
        let app = AppModel()
        let model = HistoryModel()
        model.load(app) {
            XCTAssertEqual(ConsoleOwner.module, .history)
            XCTAssertTrue(model.loading)
            let id = app.console.begin(ShellCommand("fixture-history", []))
            app.console.append(id, ["fixture history output"])
            app.console.finish(id, status: 0)
            return CommandResult(status: 0, stdout: "{\"sessions\":[]}", stderr: "")
        }
        XCTAssertTrue(model.loading)
        for _ in 0..<100 where model.loading { await Task.yield() }
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.loaded)
        XCTAssertNil(model.error)
        XCTAssertEqual(app.console.output(of: .history), ["fixture history output"])
    }

    func testFailedRefreshRetainsPriorSessionsAndAllowsRetry() async throws {
        let app = AppModel()
        let model = HistoryModel()
        model.sessions = try HistoryModel.decode(CommandResult(status: 0, stdout: "{\"sessions\":[{\"command\":\"clean\"}]}", stderr: ""))
        model.loaded = true
        model.load(app) { CommandResult(status: 1, stdout: "{}", stderr: "fixture failure") }
        for _ in 0..<100 where model.loading { await Task.yield() }
        XCTAssertFalse(model.loading)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.sessions.count, 1)
        model.load(app) { CommandResult(status: 0, stdout: "{\"sessions\":[]}", stderr: "") }
        for _ in 0..<100 where model.loading { await Task.yield() }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testToolsAndSecurityConsoleContextsRemainSeparate() async {
        let console = ConsoleLog()
        for module in [Module.tools, .security, .history] {
            await Task(module) {
                let id = console.begin(ShellCommand("fixture", [module.rawValue]))
                console.append(id, [module.rawValue])
                console.finish(id, status: 0)
            }.value
        }
        for module in [Module.tools, .security, .history] {
            XCTAssertEqual(console.output(of: module), [module.rawValue])
        }
        XCTAssertTrue(console.output(of: .cleanup).isEmpty)
    }
}
