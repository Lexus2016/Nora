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

    /// Mole 1.67 and newer print "Removed: X · N items" where older versions printed "Tracked cleanup:".
    func testMole169RemovedLineConfirmsACompletedCleanup() {
        let model = reviewed()
        model.finish(text: "=====\nCleanup complete\nRemoved: 898.0MB · 179 items\nFree space: 300.1GB (+898.0MB)\n=====", ok: true)
        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.resultHeadline, String(localized: "Cleanup command completed"))
    }

    func testReportedBytesWithoutCompletionRemainUnverified() {
        let model = reviewed()
        model.finish(text: "=====\nTracked cleanup: 2MB | Items cleaned: 1\n=====", ok: true)
        XCTAssertTrue(model.failed)
        model.finish(text: "=====\nCleanup complete\nTracked cleanup: 2MB | Items cleaned: 1\n=====", ok: true)
        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.resultHeadline, String(localized: "Cleanup command completed"))
    }

    /// Mole's notes are worded for a terminal and list folders the app never cleans; showing them
    /// raw left people unsure what to do. Only a missing permission and places Mole could not check
    /// are surfaced. The full output stays in the console.
    func testOnlyWhatTheUserCanActOnIsSurfaced() {
        let model = CleanupModel()
        model.preview = CleanPreview.parse(cleanList: "", stdout:
            "◎ Trash · skipped, grant Full Disk Access to your terminal\n⊙ Lima data · 106.50GB · ~/.lima\n"
            + "◎ Homebrew cleanup preview timed out · run brew cleanup --dry-run manually")
        XCTAssertTrue(model.needsFullDiskAccess)
        XCTAssertTrue(model.hasSkippedChecks)
    }

    /// A rescan that skips the same places again will skip them every time on this Mac: offering
    /// "Scan again" then is a dead end, so the offer is withdrawn.
    func testASkippedCheckThatRepeatsStopsOfferingAnotherScan() {
        let slow = "◎ Project caches · skipped 2 slow/incomplete root scans"
        let model = CleanupModel()
        model.present(CleanPreview.parse(cleanList: "", stdout: slow))
        XCTAssertTrue(model.hasSkippedChecks)
        XCTAssertFalse(model.skippedChecksRepeated, "the first time, scanning again is a sensible suggestion")
        model.present(CleanPreview.parse(cleanList: "", stdout: slow))
        XCTAssertTrue(model.skippedChecksRepeated, "the same places again: another scan will not help")
        model.present(CleanPreview.parse(cleanList: "", stdout: "◎ Homebrew cleanup preview timed out · run brew cleanup --dry-run manually"))
        XCTAssertFalse(model.skippedChecksRepeated, "a different set of places is new information")
        model.present(CleanPreview.parse(cleanList: "", stdout: ""))
        XCTAssertFalse(model.hasSkippedChecks)
        XCTAssertFalse(model.skippedChecksRepeated)
    }

    private let slowPlaces = "◎ Project caches · skipped 2 slow/incomplete root scans"

    /// "Start over" begins a new session: what the previous scans skipped must not decide whether the
    /// new one offers another scan.
    func testStartingOverForgetsWhichPlacesWereSkipped() {
        let model = CleanupModel()
        model.present(CleanPreview.parse(cleanList: "", stdout: slowPlaces))
        model.present(CleanPreview.parse(cleanList: "", stdout: slowPlaces))
        XCTAssertTrue(model.skippedChecksRepeated)
        model.reset()
        model.present(CleanPreview.parse(cleanList: "", stdout: slowPlaces))
        XCTAssertFalse(model.skippedChecksRepeated)
    }

    func testFinishingARunForgetsWhichPlacesWereSkipped() {
        let model = CleanupModel()
        model.present(CleanPreview.parse(cleanList: "", stdout: slowPlaces))
        model.present(CleanPreview.parse(cleanList: "", stdout: slowPlaces))
        XCTAssertTrue(model.skippedChecksRepeated)
        model.finish(text: "=====\nCleanup complete\nRemoved: 1.0MB · 1 item\n=====", ok: true)
        model.present(CleanPreview.parse(cleanList: "", stdout: slowPlaces))
        XCTAssertFalse(model.skippedChecksRepeated, "days later the first scan is a first scan")
    }

    /// The counts in Mole's note change from run to run ("skipped 2" then "skipped 1"); the kind of skip does not.
    func testASkippedPlaceIsTheSameWhateverTheCountsInItsNote() {
        let model = CleanupModel()
        model.present(CleanPreview.parse(cleanList: "", stdout: slowPlaces))
        model.present(CleanPreview.parse(cleanList: "", stdout: "◎ Project caches · skipped 1 slow/incomplete root scans"))
        XCTAssertTrue(model.skippedChecksRepeated)
        model.present(CleanPreview.parse(cleanList: "", stdout: "◎ Project caches · preview timed out"))
        XCTAssertFalse(model.skippedChecksRepeated, "a different reason is new information")
    }

    /// Mole prints "System was already clean; no additional space freed." instead of a "Removed:" line when
    /// there was nothing left to remove. The command succeeded; that is not an unverified result.
    func testACleanRunThatFoundNothingToRemoveIsNotAFailure() {
        for line in ["System was already clean; no additional space freed.", "No additional space freed."] {
            let model = reviewed()
            model.finish(text: "=====\nCleanup complete\n\(line)\nFree space: 300.1GB\n=====", ok: true)
            XCTAssertFalse(model.failed, line)
            XCTAssertEqual(model.resultHeadline, String(localized: "Cleanup command completed"), line)
            XCTAssertFalse(model.resultLines.contains(String(localized: "These are Mole's reported results, not a measurement of newly available disk space.")), line)
        }
    }

    func testARemovedLineWithALeadingMarkStillConfirmsTheRun() {
        let model = reviewed()
        model.finish(text: "=====\nCleanup complete\n✓ Removed: 898.0MB · 179 items\n=====", ok: true)
        XCTAssertFalse(model.failed)
    }

    func testReviewOnlyRowsProtectedItemsAndSudoAreNotSurfacedAsProblems() {
        let model = CleanupModel()
        model.preview = CleanPreview.parse(cleanList: "", stdout:
            "⊙ Docker Desktop data · 56.71GB · ~/Library/Containers/com.docker.docker/Data\n⊙ Lima data · 106.50GB · ~/.lima\n"
            + "◎ Xcode documentation cache · skipped 3 protected items\n"
            + "◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview")
        XCTAssertFalse(model.needsFullDiskAccess)
        XCTAssertFalse(model.hasSkippedChecks)
        XCTAssertTrue(model.preview?.needsSudoForSystem ?? false, "the sudo control has its own notice")
    }

    func testRecoveryErrorIsNotDescribedAsActiveTask() {
        XCTAssertEqual(CleanupModel.describe(WhitelistOverlayError.pendingRecovery),
                       String(localized: "Protection recovery is required before another cleanup. Retry recovery and scan again."))
    }
}
