import Foundation
import XCTest
import MoleKit
@testable import Nora

@MainActor
final class CleanupLifecycleRegressionTests: XCTestCase {
    private func reviewed() -> CleanupModel {
        let model = CleanupModel()
        let now = Date()
        model.preview = CleanPreview.validated(
            stdout: "Dry run complete\nPotential space: 2MB | Items: 1\nDetailed file list: synthetic",
            list: "=== Caches ===\n/Users/example/Library/Caches/Synthetic  # 2MB\n", listModified: now, since: now)
        model.selected = Set(model.preview?.items.map(\.path) ?? [])
        model.stage = .review
        return model
    }

    func testOnlyCurrentValidatedSelectionsAreRunnable() {
        let model = reviewed()
        XCTAssertTrue(model.canClean)
        model.selected.insert("/Users/example/unreviewed")
        XCTAssertFalse(model.canClean)
        model.selected.remove("/Users/example/unreviewed")
        model.preview?.isComplete = false
        XCTAssertFalse(model.canClean)
    }

    func testResetClearsNestedRouteAndOldSnapshot() {
        let model = reviewed()
        model.openList("Caches")
        model.reset()
        XCTAssertFalse(model.showList)
        XCTAssertNil(model.listSection)
        XCTAssertNil(model.preview)
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertFalse(model.canClean)
        XCTAssertEqual(model.stage, .start)
    }

    func testResetCannotOrphanRunningCleanupOrRecovery() {
        let model = reviewed()
        model.stage = .running
        model.reset()
        XCTAssertEqual(model.stage, .running)
        model.stage = .done
        model.recoveryRequired = true
        model.reset()
        XCTAssertEqual(model.stage, .done)
        XCTAssertTrue(model.recoveryRequired)
    }

    func testMissingSummaryNeverReportsPreviewBytesAsSuccess() {
        let model = reviewed()
        model.finish(text: "command exited", ok: true)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(model.resultHeadline, String(localized: "Cleanup result is unverified"))
        XCTAssertFalse(model.resultLines.isEmpty)
    }

    func testFailedCommandDoesNotBecomeSuccessWithReportedBytes() {
        let model = reviewed()
        model.finish(text: "=====\nTracked cleanup: 2MB | Items cleaned: 1\n=====", ok: false)
        XCTAssertTrue(model.failed)
        XCTAssertEqual(model.resultHeadline, String(localized: "Cleanup stopped"))
    }

    func testReportedBytesWithoutCompletionRemainUnverified() {
        let model = reviewed()
        model.finish(text: "=====\nTracked cleanup: 2MB | Items cleaned: 1\n=====", ok: true)
        XCTAssertTrue(model.failed)
        model.finish(text: "=====\nCleanup complete\nTracked cleanup: 2MB | Items cleaned: 1\n=====", ok: true)
        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.resultHeadline, String(localized: "Cleanup command completed"))
    }

    func testAllWarningsRemainAvailableAndPermissionsComeFirst() {
        let model = CleanupModel()
        model.preview = CleanPreview.parse(cleanList: "", stdout:
            "◎ First note\n⊙ Second note\n◎ Third note\n◎ Fourth note\n◎ Trash: Full Disk Access required")
        XCTAssertEqual(model.reviewNotes.count, 5)
        XCTAssertTrue(model.reviewNotes[0].text.contains("Full Disk Access"))
        XCTAssertEqual(model.reviewNotes[1].text, "First note")
    }

    func testRecoveryErrorIsNotDescribedAsActiveTask() {
        XCTAssertEqual(CleanupModel.describe(WhitelistOverlayError.pendingRecovery),
                       String(localized: "Protection recovery is required before another cleanup. Retry recovery and scan again."))
    }
}
