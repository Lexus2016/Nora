import Foundation
import MoleKit
import XCTest
@testable import Nora

/// Every dependency is injected. These tests cannot scan or empty the user's real Trash.
@MainActor
final class TrashReminderTests: XCTestCase {
    func testDebouncesSubtreeEventsIntoOneSnapshot() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 1)
        fixture.events.emitChange()
        fixture.clock.advance(by: 0.5)
        fixture.events.emitChange()
        fixture.clock.advance(by: 0.5)
        fixture.events.emitChange()
        fixture.clock.advance(by: 0.99)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 1)
        fixture.clock.advance(by: 0.01)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 2)
        fixture.model.shutdown()
    }

    func testTenSecondFallbackDoesNotRecursivelyScanIdleTrash() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        fixture.clock.advance(by: 60)
        await settle()
        XCTAssertEqual(fixture.events.probes, 6)
        XCTAssertEqual(fixture.service.scanCount, 1, "An unchanged root probe must not start another recursive snapshot")
        fixture.events.changed = true
        fixture.clock.advance(by: 10)
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 2)
        fixture.model.shutdown()
    }

    func testStaleAsyncResultIsDiscardedAndScansNeverOverlap() async {
        let fixture = Fixture()
        fixture.service.holdScan = true
        fixture.model.start()
        await settle()
        XCTAssertEqual(fixture.service.activeScans, 1)
        fixture.events.emitChange()
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 1)
        fixture.service.holdScan = false
        fixture.service.current = sample("new", bytes: 99)
        fixture.service.releaseScan(sample("stale", bytes: 1))
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 2)
        XCTAssertEqual(fixture.service.maximumActiveScans, 1)
        XCTAssertEqual(fixture.model.snapshot?.contentIdentity, "new")
        fixture.model.shutdown()
    }

    func testDismissedUnchangedSnapshotNeverRepeatsButNewArrivalIsOfferedAtOnce() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        XCTAssertTrue(fixture.model.isPresented)
        fixture.model.dismiss()
        fixture.events.emitChange()
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        fixture.clock.advance(by: 3_600)
        await settle()
        XCTAssertFalse(fixture.model.isPresented, "Unchanged dismissed contents stay suppressed for good")

        fixture.model.openReview()
        await settle()
        fixture.model.dismiss()
        fixture.service.current = sample("changed", bytes: 1_000)
        fixture.events.emitChange()
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertTrue(fixture.model.isPresented, "Something new in the Trash is offered after the debounce, not after a 30 minute wait")
        fixture.model.shutdown()
    }

    func testReviewOnScreenCannotBeEmptiedWhileTheTrashChangesUnderIt() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        XCTAssertTrue(fixture.model.canEmptyTrash)
        let reviewed = fixture.model.snapshot?.contentIdentity
        // Something lands in the Trash; the rescan has not started yet (debounce).
        fixture.service.current = sample("with-new-file", bytes: 2_000)
        fixture.events.emitChange()
        XCTAssertFalse(fixture.model.canEmptyTrash, "The listed items are stale the moment the Trash changes")
        fixture.model.emptyTrash()
        await settle()
        XCTAssertEqual(fixture.service.executionCount, 0, "A click on the stale list must not reach the backend")
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertTrue(fixture.model.canEmptyTrash)
        XCTAssertNotEqual(fixture.model.snapshot?.contentIdentity, reviewed)
        fixture.model.emptyTrash()
        await settle()
        XCTAssertEqual(fixture.service.executedIdentity, "with-new-file", "The click after the rescan empties the whole current list")
        fixture.model.shutdown()
    }

    func testItemsThrownAwayDuringCleanupAreOfferedWhenItFinishes() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        fixture.service.holdExecution = true
        fixture.model.emptyTrash()
        await settle()
        // The backend leaves later arrivals alone and the model ignores events while it runs.
        fixture.service.current = sample("arrived-during-cleanup", bytes: 300)
        fixture.events.emitChange()
        fixture.clock.advance(by: 5)
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        let scans = fixture.service.scanCount
        fixture.service.releaseExecution(.init(status: .completed, deletedEntryCount: 4, detail: "Synthetic result."))
        await settle()
        XCTAssertEqual(fixture.service.scanCount, scans + 1, "Finishing a cleanup looks at the Trash again")
        XCTAssertTrue(fixture.model.isPresented, "What arrived while cleaning is offered, not silenced for half an hour")
        XCTAssertEqual(fixture.model.snapshot?.contentIdentity, "arrived-during-cleanup")
        fixture.model.shutdown()
    }

    func testCleanupThatFindsTheTrashChangedReopensTheCurrentList() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.service.holdExecution = true
        fixture.model.emptyTrash()
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        fixture.service.current = sample("changed-since-review", bytes: 700)
        fixture.service.releaseExecution(.init(status: .requiresNewReview, deletedEntryCount: 1, detail: "Trash changed since review."))
        await settle()
        XCTAssertTrue(fixture.model.isPresented, "A half-done cleanup must not leave the user without a window")
        XCTAssertTrue(fixture.model.changedDuringCleanup)
        XCTAssertEqual(fixture.model.phase, .review)
        XCTAssertTrue(fixture.model.canEmptyTrash)
        XCTAssertEqual(fixture.model.snapshot?.contentIdentity, "changed-since-review")
        fixture.model.dismiss()
        XCTAssertFalse(fixture.model.changedDuringCleanup)
        fixture.model.shutdown()
    }

    func testClosingAnUnavailableReviewKeepsThePreviousDismissal() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        XCTAssertTrue(fixture.model.isPresented)
        fixture.model.dismiss() // batch A is waved off
        // The user reopens the review, the scan fails, and the empty panel is closed again.
        fixture.service.scanError = FixtureError.unreadable
        fixture.model.openReview()
        await settle()
        XCTAssertNil(fixture.model.snapshot)
        fixture.model.dismiss()
        // Finder touches the Trash: the very same batch A is measured again.
        fixture.service.scanError = nil
        fixture.events.emitChange()
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertFalse(fixture.model.isPresented, "Closing a panel with nothing to dismiss must not forget batch A")
        fixture.model.shutdown()
    }

    func testNotNowRightAfterAnArrivalOffersTheNewItemAgain() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        XCTAssertTrue(fixture.model.isPresented)
        fixture.service.current = sample("dropped-a-moment-ago")
        fixture.events.emitChange()
        // "Not now" lands inside the debounce window: it covers the list that was on screen, not the new item.
        fixture.model.dismiss()
        XCTAssertFalse(fixture.model.isPresented)
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertTrue(fixture.model.isPresented, "The item that arrived after the list was shown is not covered by Not now")
        XCTAssertEqual(fixture.model.snapshot?.contentIdentity, "dropped-a-moment-ago")
        fixture.model.shutdown()
    }

    func testToggleOffStopsWatchAndRejectsPendingResultButManualReviewStillWorks() async {
        let fixture = Fixture()
        fixture.service.holdScan = true
        fixture.model.start()
        await settle()
        fixture.model.setRemindersEnabled(false)
        XCTAssertFalse(fixture.model.isMonitoring)
        fixture.service.holdScan = false
        fixture.service.releaseScan(sample("late"))
        await settle()
        XCTAssertNil(fixture.model.snapshot)
        XCTAssertFalse(fixture.model.isPresented)
        fixture.events.emitChange()
        fixture.clock.advance(by: 60)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 1)
        fixture.model.openReview()
        await settle()
        XCTAssertTrue(fixture.model.isPresented)
        XCTAssertEqual(fixture.model.phase, .review)
        XCTAssertFalse(fixture.model.remindersEnabled)
        XCTAssertEqual(fixture.service.scanCount, 2)
        fixture.model.shutdown()
    }

    func testWakeRechecksRootWithoutStartingDeletion() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        fixture.events.emitWake()
        XCTAssertEqual(fixture.events.probes, 1)
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertEqual(fixture.model.phase, .review)
        fixture.model.shutdown()
    }

    func testLifecycleOwnsOneWatchAndNoTimersSurviveShutdown() async {
        let fixture = Fixture()
        fixture.model.start()
        fixture.model.start()
        await settle()
        XCTAssertEqual(fixture.events.starts, 1)
        fixture.model.shutdown()
        await fixture.model.waitUntilSettled()
        fixture.clock.advance(by: 3_600)
        fixture.events.emitWake()
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        XCTAssertEqual(fixture.events.probes, 0)
        XCTAssertEqual(fixture.service.scanCount, 1)
    }

    func testDeletionUsesDisplayedSnapshotWithoutRescanning() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.service.current = sample("replacement", bytes: 5_000)
        fixture.model.emptyTrash()
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 1)
        XCTAssertEqual(fixture.service.executedIdentity, "first")
        XCTAssertEqual(fixture.service.executionCount, 1)
        XCTAssertFalse(fixture.model.isPresented)
        fixture.model.shutdown()
    }

    func testOneClickClosesImmediatelyAndDoubleClickRunsOnce() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        XCTAssertTrue(fixture.model.isPresented)
        XCTAssertEqual(fixture.service.executionCount, 0)
        var presentations: [Bool] = []
        fixture.model.presentationChanged = { presentations.append($0) }
        fixture.service.holdExecution = true
        fixture.model.emptyTrash()
        XCTAssertFalse(fixture.model.isPresented)
        XCTAssertEqual(presentations, [false])
        XCTAssertEqual(fixture.model.phase, .cleaning)
        XCTAssertTrue(fixture.model.blocksOtherMutations)
        fixture.model.emptyTrash()
        await settle()
        XCTAssertEqual(fixture.service.executionCount, 1)
        XCTAssertEqual(fixture.service.scanCount, 1)
        XCTAssertEqual(fixture.service.executedIdentity, "first")
        fixture.events.emitChange()
        fixture.clock.advance(by: 15)
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        XCTAssertEqual(fixture.service.scanCount, 1)
        fixture.model.cancelCurrentOperation()
        XCTAssertTrue(fixture.model.stopRequested)
        fixture.service.releaseExecution(.init(status: .cancelled, deletedEntryCount: 2, detail: "Synthetic cancellation after two entries."))
        await settle()
        XCTAssertEqual(fixture.model.phase, .finished)
        XCTAssertEqual(fixture.model.outcome?.deletedEntryCount, 2)
        XCTAssertEqual(fixture.model.outcome?.status, .cancelled)
        XCTAssertFalse(fixture.model.isPresented)
        XCTAssertFalse(fixture.model.blocksOtherMutations)
        fixture.model.shutdown()
    }

    func testExternalBusyAndLegacyRecoveryBlockDeletion() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.model.externalBlocker = { .busy("Synthetic app update is using Trash.") }
        fixture.model.emptyTrash()
        XCTAssertEqual(fixture.model.phase, .unavailable)
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.model.externalBlocker = { .recovery("Synthetic legacy handover is unresolved.") }
        fixture.model.openReview()
        XCTAssertEqual(fixture.model.phase, .recoveryRequired)
        fixture.model.recoverPreservedItems()
        await settle()
        XCTAssertEqual(fixture.service.recoveryCount, 0, "Trash recovery cannot bypass unrelated legacy handover recovery")
        fixture.model.shutdown()
    }

    func testKnownDirtyBatchWaitsForBusyOperationThenScansOnce() async {
        let fixture = Fixture()
        fixture.model.externalBlocker = { .busy("Synthetic busy operation.") }
        fixture.model.start()
        await settle()
        fixture.clock.advance(by: 20)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 0)
        fixture.model.externalBlocker = { nil }
        fixture.clock.advance(by: 10)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 1)
        fixture.clock.advance(by: 30)
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 1, "Only a previously dirty batch retries after busy settlement")
        fixture.model.shutdown()
    }

    func testBackendRecoveryBlocksScanAndRestoresWithoutDeleting() async {
        let fixture = Fixture()
        fixture.service.recovery = .init(blocksNewRun: true, detail: "Synthetic interrupted journal.")
        fixture.model.openReview()
        await settle()
        XCTAssertEqual(fixture.model.phase, .recoveryRequired)
        XCTAssertEqual(fixture.service.scanCount, 0)
        fixture.model.emptyTrash()
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.service.recovery = .init(blocksNewRun: false, detail: "Synthetic items restored.")
        fixture.model.recoverPreservedItems()
        await settle()
        XCTAssertEqual(fixture.service.recoveryCount, 1)
        XCTAssertEqual(fixture.service.executionCount, 0)
        XCTAssertEqual(fixture.model.phase, .unavailable)
        fixture.model.shutdown()
    }

    func testUnknownOrPartialReadIsNeverPresentedAsEmpty() async {
        let fixture = Fixture()
        fixture.service.scanError = FixtureError.unreadable
        fixture.model.openReview()
        await settle()
        XCTAssertEqual(fixture.model.phase, .unavailable)
        XCTAssertNil(fixture.model.snapshot)
        XCTAssertFalse(fixture.model.canEmptyTrash)
        fixture.model.emptyTrash()
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.model.shutdown()
    }

    func testShutdownCannotBeRevivedByLateStartupContinuation() async {
        let fixture = Fixture()
        fixture.model.shutdown()
        fixture.model.start()
        await fixture.model.checkRecovery()
        fixture.model.openReview()
        await settle()
        XCTAssertEqual(fixture.events.starts, 0)
        XCTAssertEqual(fixture.service.scanCount, 0)
        XCTAssertFalse(fixture.model.isWorking)
        XCTAssertFalse(fixture.model.isPresented)
    }

    func testQueuedDeletionAndRecoveryActionsCannotStartAfterShutdown() async {
        let deletion = Fixture()
        deletion.model.openReview()
        await settle()
        XCTAssertTrue(deletion.model.canEmptyTrash)
        deletion.model.shutdown()
        await deletion.model.waitUntilSettled()
        deletion.model.emptyTrash()
        await settle()
        XCTAssertFalse(deletion.model.canEmptyTrash)
        XCTAssertEqual(deletion.service.executionCount, 0)
        XCTAssertFalse(deletion.model.isWorking)

        let recovery = Fixture()
        recovery.service.recovery = .init(blocksNewRun: true, detail: "Synthetic unresolved recovery.")
        await recovery.model.checkRecovery()
        XCTAssertEqual(recovery.model.phase, .recoveryRequired)
        recovery.model.shutdown()
        await recovery.model.waitUntilSettled()
        recovery.model.recoverPreservedItems()
        await settle()
        XCTAssertEqual(recovery.service.recoveryCount, 0)
        XCTAssertFalse(recovery.model.isWorking)
    }

    func testRecoveryStatusFailsClosedUntilCheckedEvenWhenRemindersAreOff() async {
        let fixture = Fixture()
        fixture.model.setRemindersEnabled(false)
        XCTAssertTrue(fixture.model.blocksOtherMutations)
        fixture.service.recovery = .init(blocksNewRun: true, detail: "Synthetic pending journal.")
        await fixture.model.checkRecovery()
        XCTAssertTrue(fixture.model.recoveryChecked)
        XCTAssertTrue(fixture.model.recoveryPending)
        XCTAssertTrue(fixture.model.blocksOtherMutations)
        XCTAssertFalse(fixture.model.isMonitoring)
        XCTAssertEqual(fixture.service.scanCount, 0)
        fixture.service.recovery = .init(blocksNewRun: false, detail: "Synthetic restored journal.")
        fixture.model.recoverPreservedItems()
        await settle()
        XCTAssertFalse(fixture.model.blocksOtherMutations)
        fixture.model.shutdown()
    }

    func testNoAutomaticWorkInVisualOrTestHostFactory() async {
        let model = TrashReminderModel.live(visualSnapshot: true)
        model.start()
        XCTAssertFalse(model.isMonitoring)
        model.openReview()
        await settle()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.snapshot, "Even a fixture manual action cannot reach live Trash")
        model.shutdown()
    }

    func testStopWaitsForExecutionBeforeCallerCanRecoverOtherTrashOperations() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.service.holdExecution = true
        fixture.model.emptyTrash()
        await settle()
        fixture.model.shutdown()
        var settled = false
        let waiter = Task { @MainActor in await fixture.model.waitUntilSettled(); settled = true }
        await settle()
        XCTAssertFalse(settled)
        fixture.service.releaseExecution(.init(status: .cancelled, deletedEntryCount: 0, detail: "Synthetic stop."))
        await waiter.value
        XCTAssertTrue(settled)
        XCTAssertFalse(fixture.model.isPresented)
        XCTAssertFalse(fixture.model.isWorking)
    }

    func testSuccessfulBackgroundDeletionDoesNotReopenThePanel() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.model.emptyTrash()
        XCTAssertFalse(fixture.model.isPresented)
        await settle()
        XCTAssertEqual(fixture.model.phase, .finished)
        XCTAssertEqual(fixture.model.outcome?.status, .completed)
        XCTAssertFalse(fixture.model.isPresented)
        fixture.clock.advance(by: 30)
        XCTAssertFalse(fixture.model.isPresented)
        XCTAssertFalse(fixture.model.blocksOtherMutations)
        fixture.model.shutdown()
    }

    func testExplicitlyReopenedPanelStaysVisibleAfterBackgroundDeletionFinishes() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.service.holdExecution = true
        fixture.model.emptyTrash()
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        fixture.model.openReview()
        XCTAssertTrue(fixture.model.isPresented)
        XCTAssertEqual(fixture.service.scanCount, 1)
        fixture.service.releaseExecution(.init(status: .cancelled, deletedEntryCount: 1, detail: "Synthetic stop."))
        await settle()
        XCTAssertEqual(fixture.model.outcome?.status, .cancelled)
        fixture.clock.advance(by: 30)
        XCTAssertTrue(fixture.model.isPresented)

        fixture.service.holdExecution = false
        fixture.model.openReview()
        await settle()
        fixture.model.emptyTrash()
        await settle()
        XCTAssertEqual(fixture.model.outcome?.status, .completed)
        fixture.model.openReview()
        fixture.clock.advance(by: 30)
        XCTAssertTrue(fixture.model.isPresented)
        fixture.model.shutdown()
    }

    func testEmptyTrashCannotExecuteWithoutNonemptyReview() async {
        let fixture = Fixture()
        fixture.model.emptyTrash()
        fixture.service.holdScan = true
        fixture.model.openReview()
        await settle()
        fixture.model.emptyTrash()
        fixture.service.releaseScan(.init(contentIdentity: "empty", topLevelItemCount: 0, entryCount: 0, logicalBytes: 0))
        await settle()
        XCTAssertEqual(fixture.model.phase, .review)
        XCTAssertFalse(fixture.model.canEmptyTrash)
        fixture.model.emptyTrash()
        await settle()
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.model.shutdown()
    }

    func testFailedOrInterruptedBackgroundDeletionStaysDismissedAndPreservesOutcome() async {
        for status in [TrashReminderOutcome.Status.failed, .cancelled, .recoveryRequired] {
            let fixture = Fixture()
            fixture.model.openReview()
            await settle()
            fixture.service.holdExecution = true
            fixture.model.emptyTrash()
            await settle()
            fixture.service.releaseExecution(.init(status: status, deletedEntryCount: 0, detail: "Synthetic unsuccessful result."))
            await settle()
            XCTAssertFalse(fixture.model.isPresented)
            XCTAssertEqual(fixture.model.outcome?.status, status)
            XCTAssertEqual(fixture.model.recoveryPending, status == .recoveryRequired)
            XCTAssertEqual(fixture.model.blocksOtherMutations, status == .recoveryRequired)
            fixture.model.shutdown()
        }
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }
    private func sample(_ id: String, bytes: Int64 = 1_400_000_000) -> TrashReminderSnapshot {
        .init(contentIdentity: id, topLevelItemCount: 2, entryCount: 4, logicalBytes: bytes)
    }

    private enum FixtureError: Error { case unreadable }

    @MainActor
    private final class Fixture {
        let clock = VirtualClock()
        let events = EventSource()
        let service = Service()
        let model: TrashReminderModel
        init() {
            model = TrashReminderModel(services: service.dependencies, monitor: events, clock: clock)
        }
    }

    @MainActor
    private final class Service {
        var current = TrashReminderSnapshot(contentIdentity: "first", topLevelItemCount: 2, entryCount: 4, logicalBytes: 1_400_000_000)
        var scanCount = 0
        var activeScans = 0
        var maximumActiveScans = 0
        var executionCount = 0
        var recoveryCount = 0
        var executedIdentity: String?
        var holdScan = false
        var holdExecution = false
        var scanError: Error?
        var recovery = TrashReminderRecovery(blocksNewRun: false, detail: "")
        private var scanContinuation: CheckedContinuation<TrashReminderSnapshot, Never>?
        private var executionContinuation: CheckedContinuation<TrashReminderOutcome, Never>?
        var dependencies: TrashReminderServices {
            .init(scan: { [self] _ in
                scanCount += 1
                activeScans += 1
                maximumActiveScans = max(maximumActiveScans, activeScans)
                defer { activeScans -= 1 }
                if let scanError { throw scanError }
                if holdScan { return await withCheckedContinuation { scanContinuation = $0 } }
                return current
            }, execute: { [self] snapshot, _ in
                executionCount += 1
                executedIdentity = snapshot.contentIdentity
                if holdExecution { return await withCheckedContinuation { executionContinuation = $0 } }
                return .init(status: .completed, deletedEntryCount: snapshot.entryCount, detail: "Synthetic result. No filesystem action.")
            }, recoveryStatus: { [self] in recovery }, recover: { [self] in recoveryCount += 1; return recovery })
        }
        func releaseScan(_ snapshot: TrashReminderSnapshot) { scanContinuation?.resume(returning: snapshot); scanContinuation = nil }
        func releaseExecution(_ result: TrashReminderOutcome) { executionContinuation?.resume(returning: result); executionContinuation = nil }
    }

    @MainActor
    private final class EventSource: TrashDirectoryMonitoring {
        var starts = 0
        var probes = 0
        var changed = false
        private var change: (() -> Void)?
        private var wake: (() -> Void)?
        func start(onChange: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {
            starts += 1; change = onChange; wake = onWake
        }
        func stop() { change = nil; wake = nil }
        func sampleRoot() -> Bool { probes += 1; defer { changed = false }; return changed }
        func emitChange() { change?() }
        func emitWake() { wake?() }
    }

    @MainActor
    private final class VirtualClock: TrashReminderScheduling {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        private var calls: [Call] = []
        func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TrashReminderScheduledCall {
            let call = Call(due: now.addingTimeInterval(seconds), action: action)
            calls.append(call)
            return call
        }
        func advance(by seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let next = calls.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
                now = next.due
                next.cancelled = true
                next.action()
            }
            calls.removeAll { $0.cancelled }
            now = target
        }
        @MainActor
        private final class Call: TrashReminderScheduledCall {
            let due: Date
            let action: @MainActor () -> Void
            var cancelled = false
            init(due: Date, action: @escaping @MainActor () -> Void) { self.due = due; self.action = action }
            func cancel() { cancelled = true }
        }
    }
}
