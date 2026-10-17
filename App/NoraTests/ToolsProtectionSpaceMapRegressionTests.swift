import XCTest
import MoleKit
@testable import Nora

/// F1/F3/F4/F5. Synthetic data and injected Trash callbacks only; no system changes.
@MainActor
final class ToolsProtectionSpaceMapRegressionTests: XCTestCase {
    private func analysis(_ paths: [(String, Int)]) throws -> DiskAnalysis {
        let rows: [[String: Any]] = paths.map { ["path": $0.0, "size": $0.1, "is_dir": true] }
        return try JSONDecoder().decode(DiskAnalysis.self, from: JSONSerialization.data(withJSONObject: ["entries": rows]))
    }

    func testParentAndChildHaveOnePlanInEitherOrder() throws {
        for rows in [[("/A", 100), ("/A/file", 40), ("/AB", 20)],
                     [("/AB", 20), ("/A/file", 40), ("/A", 100)]] {
            let model = SpaceMapModel()
            model.cache[URL(fileURLWithPath: "/")] = try analysis(rows)
            model.selected = ["/A", "/A/file", "/AB"]
            model.stage = .review
            XCTAssertEqual(model.selectedEntries.map(\.path), ["/A", "/AB"])
            XCTAssertEqual(model.selectedSize, 120)
            var moved: [String] = []
            model.trashSelected { moved.append($0.path) }
            XCTAssertEqual(moved, ["/A", "/AB"])
            XCTAssertEqual(model.trashed.count, 2)
            XCTAssertTrue(model.trashFailures.isEmpty)
            XCTAssertTrue(model.cache.isEmpty)
            model.trashSelected { _ in XCTFail("A completed plan must not run twice") }
        }
    }

    func testLexicalAliasesDeduplicateAndRootContainsEverything() throws {
        let entries = try analysis([("/A", 100), ("/A/./", 100), ("/A/b", 40), ("/", 500)]).entries
        let aliases = SpaceMapModel.topLevelSelection(entries, selected: ["/A", "/A/./", "/A/b"])
        XCTAssertEqual(aliases.count, 1)
        XCTAssertEqual(aliases.first?.size, 100)
        XCTAssertEqual(SpaceMapModel.topLevelSelection(entries, selected: ["/", "/A/b"]).map(\.path), ["/"])
    }

    func testTrashFailureDoesNotClaimTargetMoved() throws {
        let model = SpaceMapModel()
        model.cache[URL(fileURLWithPath: "/")] = try analysis([("/A", 100), ("/A/b", 40)])
        model.selected = ["/A", "/A/b"]
        model.stage = .review
        var attempts = 0
        model.trashSelected { _ in attempts += 1; throw CocoaError(.fileWriteNoPermission) }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(model.trashed.isEmpty)
        XCTAssertEqual(model.trashFailures.count, 1)
    }

    func testDefaultsFailureBlocksEditsEvenAfterEarlierSuccess() async {
        let model = ProtectionModel(write: { _, _ in XCTFail("Failed defaults must prevent writes") })
        let snapshot = ProtectionModel.Snapshot(home: URL(fileURLWithPath: "/fixture/home"),
                                               defaults: ["~/safe"], cleanLines: nil, tasks: [],
                                               optimizeLines: [], purgeLines: nil)
        await model.load { _ in snapshot }?.value
        XCTAssertTrue(model.loaded)
        await model.load { cancellation in
            try ProtectionModel.readSnapshot(home: snapshot.home, cancellation: cancellation,
                readDefaults: { throw CocoaError(.fileReadNoPermission) }, readTasks: { [] },
                readClean: { nil }, readOptimize: { [] }, readPurge: { nil })
        }?.value
        XCTAssertFalse(model.cleanupReady)
        XCTAssertFalse(model.loaded)
        XCTAssertNotNil(model.message)
        model.addPattern("~/new")
        model.removePattern("~/safe")
        XCTAssertTrue(model.custom.isEmpty)
        XCTAssertFalse(model.cleanFileExists)
    }

    func testUnreadableWhitelistIsNotAnAbsentWhitelist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("whitelist")
        XCTAssertNil(try ProtectionModel.readCleanLines(file))
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        XCTAssertThrowsError(try ProtectionModel.readCleanLines(file))
    }

    func testFailedNonemptyCompletionPreviewCannotAuthorizeAdd() {
        let model = ToolsModel()
        model.acceptCompletionPreview(.init(result: CommandResult(status: 2, stdout: "source completion.sh", stderr: "Permission denied")))
        XCTAssertFalse(model.completionPreview.isEmpty)
        XCTAssertFalse(model.completionPreviewValid)
        XCTAssertEqual(model.completionError, "Permission denied")
        model.acceptCompletionPreview(.init(result: CommandResult(status: 0, stdout: "source completion.sh", stderr: "")))
        XCTAssertTrue(model.completionPreviewValid)
        model.acceptCompletionPreview(.init(error: CocoaError(.fileReadNoPermission)))
        XCTAssertFalse(model.completionPreviewValid)
        XCTAssertNotNil(model.completionError)
    }

    func testTouchIDRequiresSuccessfulRecognizableStatus() {
        XCTAssertNil(ToolsModel.touchIDState(CommandResult(status: 1, stdout: "enabled", stderr: "failure")))
        XCTAssertNil(ToolsModel.touchIDState(CommandResult(status: 0, stdout: "unexpected output", stderr: "")))
        XCTAssertEqual(ToolsModel.touchIDState(CommandResult(status: 0, stdout: "not configured", stderr: "")), false)
        XCTAssertEqual(ToolsModel.touchIDState(CommandResult(status: 0, stdout: "enabled", stderr: "")), true)
    }
}
