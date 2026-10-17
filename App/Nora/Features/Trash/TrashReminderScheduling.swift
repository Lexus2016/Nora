import Foundation

@MainActor
protocol TrashReminderScheduledCall: AnyObject {
    func cancel()
}

/// The model's only clock. Tests advance a virtual clock instead of waiting for wall time.
@MainActor
protocol TrashReminderScheduling: AnyObject {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TrashReminderScheduledCall
}

@MainActor
final class TrashReminderClock: TrashReminderScheduling {
    var now: Date { Date() }

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any TrashReminderScheduledCall {
        ScheduledCall(seconds: seconds, action: action)
    }

    @MainActor
    private final class ScheduledCall: TrashReminderScheduledCall {
        private var task: Task<Void, Never>?
        init(seconds: TimeInterval, action: @escaping @MainActor () -> Void) {
            task = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled else { return }
                action()
            }
        }
        func cancel() { task?.cancel(); task = nil }
        deinit { task?.cancel() }
    }
}
