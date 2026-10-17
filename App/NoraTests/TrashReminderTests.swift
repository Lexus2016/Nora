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

    func testDismissedUnchangedSnapshotNeverRepeatsAndChangedBatchWaitsThirtyMinutes() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        XCTAssertTrue(fixture.model.isPresented)
        fixture.model.dismiss()
        fixture.events.emitChange()
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        fixture.clock.advance(by: 1_799)
        await settle()
        XCTAssertFalse(fixture.model.isPresented, "Unchanged dismissed contents stay suppressed after the cooldown")

        fixture.model.openReview()
        await settle()
        fixture.model.dismiss()
        fixture.service.current = sample("changed", bytes: 1_000)
        fixture.events.emitChange()
        fixture.clock.advance(by: 1)
        await settle()
        XCTAssertFalse(fixture.model.isPresented)
        let scans = fixture.service.scanCount
        fixture.clock.advance(by: 1_799)
        await settle()
        XCTAssertTrue(fixture.model.isPresented)
        XCTAssertEqual(fixture.service.scanCount, scans, "Cooldown expiry only offers the already measured changed batch")
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

    func testWakeInvalidatesConfirmationAndRechecksRoot() async {
        let fixture = Fixture()
        fixture.model.start()
        await settle()
        fixture.model.requestDeletionConfirmation()
        await settle()
        XCTAssertEqual(fixture.model.phase, .confirmation)
        fixture.events.emitWake()
        XCTAssertEqual(fixture.events.probes, 1)
        XCTAssertFalse(fixture.model.canConfirmDeletion)
        fixture.model.confirmDeletion()
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

    func testChangedReviewRequiresReviewAgainInsteadOfOpeningConfirmation() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.service.current = sample("replacement", bytes: 5_000)
        fixture.model.requestDeletionConfirmation()
        await settle()
        XCTAssertEqual(fixture.model.phase, .review)
        XCTAssertNotNil(fixture.model.notice)
        XCTAssertEqual(fixture.model.snapshot?.contentIdentity, "replacement")
        fixture.model.confirmDeletion()
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.model.shutdown()
    }

    func testRefreshThenSeparateExplicitConfirmationIsRequiredAndDoubleClickRunsOnce() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.model.confirmDeletion()
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.model.requestDeletionConfirmation()
        await settle()
        XCTAssertEqual(fixture.service.scanCount, 2)
        XCTAssertEqual(fixture.model.phase, .confirmation)
        XCTAssertEqual(fixture.service.executionCount, 0)
        fixture.service.holdExecution = true
        fixture.model.confirmDeletion()
        fixture.model.confirmDeletion()
        await settle()
        XCTAssertEqual(fixture.service.executionCount, 1)
        XCTAssertEqual(fixture.service.executedIdentity, "first")
        fixture.model.cancelCurrentOperation()
        XCTAssertTrue(fixture.model.stopRequested)
        fixture.service.releaseExecution(.init(status: .cancelled, deletedEntryCount: 2, detail: "Synthetic cancellation after two entries."))
        await settle()
        XCTAssertEqual(fixture.model.phase, .finished)
        XCTAssertEqual(fixture.model.outcome?.deletedEntryCount, 2)
        XCTAssertEqual(fixture.model.outcome?.status, .cancelled)
        fixture.model.shutdown()
    }

    func testExternalBusyAndLegacyRecoveryBlockBothDeletionSteps() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.model.requestDeletionConfirmation()
        await settle()
        fixture.model.externalBlocker = { .busy("Synthetic app update is using Trash.") }
        fixture.model.confirmDeletion()
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
        fixture.model.confirmDeletion()
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
        XCTAssertFalse(fixture.model.canReviewDeletion)
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
        deletion.model.requestDeletionConfirmation()
        await settle()
        XCTAssertTrue(deletion.model.canConfirmDeletion)
        deletion.model.shutdown()
        await deletion.model.waitUntilSettled()
        deletion.model.confirmDeletion()
        await settle()
        XCTAssertFalse(deletion.model.canConfirmDeletion)
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
        fixture.model.requestDeletionConfirmation()
        await settle()
        fixture.service.holdExecution = true
        fixture.model.confirmDeletion()
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

    func testSuccessfulDeletionClosesThePanelOnItsOwnAfterTheResultHasBeenShown() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.model.requestDeletionConfirmation()
        await settle()
        fixture.model.confirmDeletion()
        await settle()
        XCTAssertEqual(fixture.model.phase, .finished)
        XCTAssertEqual(fixture.model.outcome?.status, .completed)
        XCTAssertTrue(fixture.model.isPresented, "The result is shown first")
        fixture.clock.advance(by: TrashReminderModel.completionDisplayInterval - 0.5)
        XCTAssertTrue(fixture.model.isPresented, "Still readable just before the interval ends")
        fixture.clock.advance(by: 1)
        XCTAssertFalse(fixture.model.isPresented)
        fixture.model.shutdown()
    }

    func testCancelledDeletionAndAReopenedReviewStayOnScreen() async {
        let fixture = Fixture()
        fixture.model.openReview()
        await settle()
        fixture.model.requestDeletionConfirmation()
        await settle()
        fixture.service.holdExecution = true
        fixture.model.confirmDeletion()
        await settle()
        fixture.service.releaseExecution(.init(status: .cancelled, deletedEntryCount: 1, detail: "Synthetic stop."))
        await settle()
        XCTAssertEqual(fixture.model.outcome?.status, .cancelled)
        fixture.clock.advance(by: TrashReminderModel.completionDisplayInterval * 4)
        XCTAssertTrue(fixture.model.isPresented, "A partial result needs to be read, so it never closes by itself")

        fixture.service.holdExecution = false
        fixture.model.openReview()
        await settle()
        fixture.model.requestDeletionConfirmation()
        await settle()
        fixture.model.confirmDeletion()
        await settle()
        XCTAssertEqual(fixture.model.outcome?.status, .completed)
        fixture.model.openReview()
        fixture.clock.advance(by: TrashReminderModel.completionDisplayInterval * 2)
        XCTAssertTrue(fixture.model.isPresented, "Reopening the review cancels the pending automatic close")
        fixture.model.shutdown()
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
