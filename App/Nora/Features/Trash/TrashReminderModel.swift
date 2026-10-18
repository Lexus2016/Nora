import Foundation
import MoleKit
import Observation

/// App-owned coordinator. No scan or command is started by a SwiftUI appearance callback.
@MainActor @Observable
final class TrashReminderModel {
    enum Phase: Equatable {
        case idle, scanning, review, cleaning, finished, unavailable, recoveryRequired
    }
    private enum ScanPurpose: Equatable { case automatic, manual }
    private enum WorkKind: Equatable { case scan, execution, recovery }

    private(set) var phase: Phase = .idle
    private(set) var snapshot: TrashReminderSnapshot?
    private(set) var isPresented = false
    private(set) var remindersEnabled: Bool
    private(set) var notice: String?
    private(set) var diagnostic: String?
    private(set) var outcome: TrashReminderOutcome?
    private(set) var stopRequested = false
    private(set) var operationInProgress = false
    private(set) var canCancelOperation = false
    private(set) var isMonitoring = false
    private(set) var recoveryChecked = false
    private(set) var recoveryPending = false

    /// Integration sets this to cover legacy app-handover recovery and concurrent app updates.
    @ObservationIgnored var externalBlocker: @MainActor () -> TrashReminderBlock? = { nil }
    @ObservationIgnored var presentationChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private let services: TrashReminderServices
    @ObservationIgnored private let monitor: any TrashDirectoryMonitoring
    @ObservationIgnored private let clock: any TrashReminderScheduling
    @ObservationIgnored private let preferences: UserDefaults?
    @ObservationIgnored private let permitsMonitoring: Bool
    @ObservationIgnored private var debounce: (any TrashReminderScheduledCall)?
    @ObservationIgnored private var fallback: (any TrashReminderScheduledCall)?
    @ObservationIgnored private var cooldown: (any TrashReminderScheduledCall)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workKind: WorkKind?
    @ObservationIgnored private var cancellation: TrashCancellationToken?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingScan: ScanPurpose?
    @ObservationIgnored private var dismissedSnapshot: TrashReminderSnapshot?
    @ObservationIgnored private var dismissUntil: Date?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var refreshAfterBusy = false

    static let preferenceKey = "trashRemindersEnabled"
    static let fallbackInterval: TimeInterval = 10
    static let debounceInterval: TimeInterval = 1
    static let dismissalCooldown: TimeInterval = 30 * 60

    init(services: TrashReminderServices, monitor: any TrashDirectoryMonitoring,
         clock: any TrashReminderScheduling = TrashReminderClock(), preferences: UserDefaults? = nil,
         enabled: Bool = true, permitsMonitoring: Bool = true) {
        self.services = services
        self.monitor = monitor
        self.clock = clock
        self.preferences = preferences
        self.remindersEnabled = preferences?.object(forKey: Self.preferenceKey) as? Bool ?? enabled
        self.permitsMonitoring = permitsMonitoring
    }

    static func live(visualSnapshot: Bool = false) -> TrashReminderModel {
        let environment = ProcessInfo.processInfo.environment
        let isTest = environment["NORA_UNIT_TESTING"] == "1" || environment["XCTestConfigurationFilePath"] != nil
        let disabled = visualSnapshot || isTest
        let services: TrashReminderServices
        let monitor: any TrashDirectoryMonitoring
        if disabled {
            services = .disabled
            monitor = InertTrashDirectoryMonitor()
        } else {
            services = .live()
            monitor = TrashDirectoryMonitor()
        }
        let model = TrashReminderModel(services: services, monitor: monitor,
                                      preferences: disabled ? nil : .standard, permitsMonitoring: !disabled)
        model.recoveryChecked = disabled
        return model
    }

    var canEmptyTrash: Bool { !stopped && phase == .review && (snapshot?.topLevelItemCount ?? 0) > 0 && work == nil }
    var isWorking: Bool { operationInProgress }
    /// Unknown startup status fails closed until the app awaits checkRecovery().
    var blocksOtherMutations: Bool { isWorking || !recoveryChecked || recoveryPending }

    /// Call once at app startup even if reminders are disabled. This probe never deletes or restores.
    func checkRecovery() async {
        guard !stopped else { return }
        if let work { await work.value; return }
        workKind = .recovery
        operationInProgress = true
        canCancelOperation = false
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.services.recoveryStatus()
            self.recoveryChecked = true
            self.recoveryPending = result.blocksNewRun
            if result.blocksNewRun { self.blockCleanup(.recovery(result.detail)) }
            self.finishWork()
        }
        await work?.value
    }

    func start() {
        guard !stopped, permitsMonitoring, remindersEnabled, !isMonitoring else { return }
        isMonitoring = true
        monitor.start(onChange: { [weak self] in self?.directoryChanged() }, onWake: { [weak self] in self?.systemDidWake() })
        scheduleFallback()
        enqueueScan(.automatic)
    }

    func shutdown() {
        stopped = true
        stopMonitoring()
        invalidateScan()
        cancellation?.cancel()
        pendingScan = nil
        present(false)
    }

    /// Await this after shutdown before other recovery code may restore items into Trash.
    func waitUntilSettled() async {
        let current = work
        await current?.value
    }

    func setRemindersEnabled(_ enabled: Bool) {
        guard remindersEnabled != enabled else { return }
        remindersEnabled = enabled
        preferences?.set(enabled, forKey: Self.preferenceKey)
        if enabled {
            start()
        } else {
            stopMonitoring()
            invalidateScan()
            pendingScan = nil
            present(false)
        }
    }

    /// Always available from Nora's menu and settings, even when automatic reminders are off.
    func openReview() {
        guard !stopped else { return }
        present(true)
        guard workKind != .execution && workKind != .recovery else { return }
        enqueueScan(.manual)
    }

    func dismiss() {
        dismissedSnapshot = snapshot
        dismissUntil = clock.now.addingTimeInterval(Self.dismissalCooldown)
        cooldown?.cancel()
        cooldown = clock.schedule(after: Self.dismissalCooldown) { [weak self] in
            guard let self, self.isMonitoring, !self.isPresented else { return }
            // No disk scan at cooldown expiry: only a changed, previously measured batch is eligible.
            self.offerCurrentSnapshot()
        }
        if workKind == .scan { invalidateScan(); pendingScan = nil }
        present(false)
    }

    /// Start the displayed batch and hide the panel immediately, without another scan or confirmation.
    /// Запустити очищення показаного списку й одразу сховати вікно без повторної перевірки чи підтвердження.
    func emptyTrash() {
        guard canEmptyTrash, let reviewed = snapshot else { return }
        if let block = externalBlocker() { blockCleanup(block); return }
        phase = .cleaning
        notice = nil
        stopRequested = false
        let token = TrashCancellationToken()
        cancellation = token
        workKind = .execution
        operationInProgress = true
        canCancelOperation = true
        dismiss()
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            // The backend revalidates the frozen manifest and never sweeps later arrivals.
            let result = await self.services.execute(reviewed, token)
            self.outcome = result
            self.recoveryChecked = true
            self.recoveryPending = result.status == .recoveryRequired
            self.diagnostic = result.detail
            self.phase = result.status == .recoveryRequired ? .recoveryRequired : .finished
            self.snapshot = nil
            self.dismissedSnapshot = reviewed
            self.dismissUntil = self.clock.now.addingTimeInterval(Self.dismissalCooldown)
            self.finishWork()
        }
    }

    func cancelCurrentOperation() {
        guard work != nil, canCancelOperation else { return }
        stopRequested = true
        cancellation?.cancel()
        if workKind == .scan {
            invalidateScan()
            pendingScan = nil
            snapshot = nil
            phase = .unavailable
            notice = String(localized: "Trash check was cancelled. Review again before deleting.")
        }
    }

    /// Recovery only restores/preserves staged entries; it never resumes permanent deletion.
    func recoverPreservedItems() {
        guard !stopped, phase == .recoveryRequired, work == nil else { return }
        guard externalBlocker() == nil else { return }
        workKind = .recovery
        operationInProgress = true
        canCancelOperation = false
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.services.recover()
            self.recoveryChecked = true
            self.recoveryPending = result.blocksNewRun
            self.diagnostic = result.detail
            self.phase = result.blocksNewRun ? .recoveryRequired : .unavailable
            self.notice = result.blocksNewRun ? nil : String(localized: "Trash recovery finished. Review the remaining items again.")
            self.finishWork()
        }
    }

    func directoryChanged() {
        guard isMonitoring else { return }
        guard workKind != .execution && workKind != .recovery else { return }
        invalidateScan()
        debounce?.cancel()
        debounce = clock.schedule(after: Self.debounceInterval) { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.debounce = nil
            self.enqueueScan(.automatic)
        }
    }

    func systemDidWake() {
        guard isMonitoring else { return }
        _ = monitor.sampleRoot()
        directoryChanged()
    }

    private func stopMonitoring() {
        isMonitoring = false
        monitor.stop()
        debounce?.cancel(); debounce = nil
        fallback?.cancel(); fallback = nil
        cooldown?.cancel(); cooldown = nil
        refreshAfterBusy = false
    }

    private func scheduleFallback() {
        fallback?.cancel()
        fallback = clock.schedule(after: Self.fallbackInterval) { [weak self] in
            guard let self, self.isMonitoring else { return }
            if self.monitor.sampleRoot() { self.directoryChanged() }
            else if self.refreshAfterBusy, self.externalBlocker() == nil, self.work == nil {
                self.refreshAfterBusy = false
                self.enqueueScan(.automatic)
            }
            self.scheduleFallback()
        }
    }

    private func invalidateScan() {
        generation += 1
        if workKind == .scan { cancellation?.cancel() }
    }

    private func enqueueScan(_ purpose: ScanPurpose) {
        guard !stopped else { return }
        if work != nil {
            guard workKind == .scan else { return }
            pendingScan = purpose
            invalidateScan()
            return
        }
        if let block = externalBlocker() {
            if case .busy = block { refreshAfterBusy = isMonitoring }
            if isPresented || purpose != .automatic { blockCleanup(block) }
            return
        }
        refreshAfterBusy = false
        generation += 1
        let expectedGeneration = generation
        let token = TrashCancellationToken()
        cancellation = token
        workKind = .scan
        operationInProgress = true
        canCancelOperation = true
        phase = .scanning
        notice = nil
        diagnostic = nil
        outcome = nil
        stopRequested = false
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            let recovery = await self.services.recoveryStatus()
            self.recoveryChecked = true
            self.recoveryPending = recovery.blocksNewRun
            guard expectedGeneration == self.generation else { self.finishWork(); return }
            if recovery.blocksNewRun {
                self.blockCleanup(.recovery(recovery.detail))
                self.finishWork()
                return
            }
            do {
                let next = try await self.services.scan(token)
                guard expectedGeneration == self.generation else { self.finishWork(); return }
                self.snapshot = next
                self.phase = .review
                if purpose != .automatic { self.present(true) }
                else { self.offerCurrentSnapshot() }
            } catch {
                guard expectedGeneration == self.generation else { self.finishWork(); return }
                // Failed, partial, denied, and timed-out reads are unknown, never an empty Trash.
                self.snapshot = nil
                self.phase = .unavailable
                self.diagnostic = error.localizedDescription
                self.notice = String(localized: "Trash size is unavailable. Check access and try again.")
                if purpose != .automatic { self.present(true) }
            }
            self.finishWork()
        }
    }

    private func finishWork() {
        work = nil
        workKind = nil
        operationInProgress = false
        canCancelOperation = false
        cancellation = nil
        if let pendingScan {
            self.pendingScan = nil
            enqueueScan(pendingScan)
        }
    }

    private func offerCurrentSnapshot() {
        guard remindersEnabled, isMonitoring, !isPresented, externalBlocker() == nil,
              let snapshot, snapshot.topLevelItemCount > 0 else { return }
        if let dismissedSnapshot, snapshot.matchesContents(of: dismissedSnapshot) { return }
        if let dismissUntil, clock.now < dismissUntil { return }
        phase = .review
        present(true)
    }

    private func blockCleanup(_ block: TrashReminderBlock) {
        snapshot = nil
        switch block {
        case .busy(let detail):
            phase = .unavailable
            diagnostic = detail
            notice = String(localized: "Another operation is using Trash. Wait until it finishes, then review again.")
        case .recovery(let detail):
            phase = .recoveryRequired
            diagnostic = detail
            notice = String(localized: "Finish the pending recovery in Nora before emptying Trash.")
        }
    }

    private func present(_ visible: Bool) {
        guard isPresented != visible else { return }
        isPresented = visible
        presentationChanged?(visible)
    }

    #if DEBUG
    enum SnapshotOperation: Equatable { case idle, scanning, cleaning, recovering }

    /// Presentation state only. The fixture is terminally stopped so even a queued control action
    /// cannot start a scanner, executor, recovery operation, or watcher. No Task/token is created.
    func setSnapshotFixture(phase: Phase, snapshot: TrashReminderSnapshot?, notice: String? = nil,
                            outcome: TrashReminderOutcome? = nil, operation: SnapshotOperation? = nil,
                            stopRequested: Bool = false) {
        precondition(!permitsMonitoring && !isMonitoring && !snapshotFixtureHasScheduledWork)
        let operation = operation ?? (phase == .scanning ? .scanning : phase == .cleaning ? .cleaning : .idle)
        precondition(!stopRequested || operation == .scanning || operation == .cleaning)
        stopped = true
        self.phase = phase
        self.snapshot = snapshot
        self.notice = notice
        self.outcome = outcome
        self.stopRequested = stopRequested
        operationInProgress = operation != .idle
        canCancelOperation = operation == .scanning || operation == .cleaning
        recoveryChecked = true
        recoveryPending = phase == .recoveryRequired
        switch operation {
        case .idle: workKind = nil
        case .scanning: workKind = .scan
        case .cleaning: workKind = .execution
        case .recovering: workKind = .recovery
        }
    }

    /// Distinguishes a rendered busy state from real work in native image assertions.
    var snapshotFixtureHasScheduledWork: Bool {
        work != nil || cancellation != nil || debounce != nil || fallback != nil || cooldown != nil || pendingScan != nil
    }
    #endif
}
