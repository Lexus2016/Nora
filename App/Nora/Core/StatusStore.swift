import Foundation
import MoleKit
import Observation

/// One `mo status --watch` stream shared by the window and the menu bar. It runs only while
/// something that shows it is visible, and keeps 120 points of history per metric.
///
/// The observed values below change only while a screen that shows them is on screen. The menu
/// bar title needs the stream but no redraws, and a screen left in a closed window still observes
/// these values: published on every sample, System Status went on redrawing there at 23% of a core.
@MainActor @Observable
final class StatusStore {
    private(set) var snapshot: StatusSnapshot?
    private(set) var cpu: [Double] = []
    private(set) var memory: [Double] = []
    private(set) var download: [Double] = []
    private(set) var upload: [Double] = []
    private(set) var diskRead: [Double] = []
    private(set) var diskWrite: [Double] = []
    private(set) var lastError: String?
    /// When the last sample arrived; shown when the stream has failed after delivering data.
    private(set) var lastSampleAt: Date?
    private(set) var isStreaming = false

    /// The snapshot while it is current: the stream runs, has no error and sent a sample in the
    /// last 15 s. Views that show bare numbers without a stale notice (the quick menu) read this,
    /// so old values never pass for live ones.
    var liveSnapshot: StatusSnapshot? {
        guard isStreaming, lastError == nil, let lastSampleAt, Date().timeIntervalSince(lastSampleAt) < 15 else { return nil }
        return snapshot
    }

    /// The same for readers outside SwiftUI (the menu bar title): current whether or not a screen
    /// is on screen.
    var currentSnapshot: StatusSnapshot? {
        guard isStreaming, lastError == nil, let latestAt, Date().timeIntervalSince(latestAt) < 15 else { return nil }
        return latest
    }

    static let historyLength = 120

    /// What the stream delivered, copied to the observed values while `viewers > 0`.
    @ObservationIgnored private var latest: StatusSnapshot?
    @ObservationIgnored private var latestAt: Date?
    @ObservationIgnored private var series = [[Double]](repeating: [], count: 6)
    /// Screens on screen that show the values; each also counts toward `demand`.
    @ObservationIgnored private var viewers = 0

    @ObservationIgnored private var mole: Mole?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// Bumped on every start, so a cancelled loop that is still finishing cannot write samples
    /// (or clear the error) over the current one.
    @ObservationIgnored private var generation = 0

    func attach(_ mole: Mole) {
        // A different Mole (updated, reinstalled, chosen in Settings): the running stream still
        // points at the old executable, so it restarts.
        let changed = self.mole?.executable != mole.executable || self.mole?.version != mole.version
        self.mole = mole
        if changed, task != nil {
            task?.cancel()
            task = nil
        }
        if demand > 0 { start() }
    }

    /// A screen that shows the values came on screen; pair with `release()`. Use
    /// `showsLiveStatus(_:)` rather than calling these from a view.
    func retain() {
        viewers += 1
        if viewers == 1 { publish() }
        retainStream()
    }

    func release() {
        viewers = max(0, viewers - 1)
        releaseStream()
    }

    /// The stream without redraws, for the menu bar title; pair with `releaseStream()`.
    func retainStream() {
        demand += 1
        stopTask?.cancel()
        if task == nil { start() }
    }

    func releaseStream() {
        demand = max(0, demand - 1)
        guard demand == 0 else { return }
        // A short grace period keeps the stream when the user just switches sections.
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func start() {
        guard let mole, task == nil else { return }
        isStreaming = true
        generation += 1
        let current = generation
        task = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    for try await snapshot in StatusStream.snapshots(mole) {
                        guard self?.generation == current else { return }
                        self?.ingest(snapshot)
                        delay = 1
                    }
                    // Mole closed the stream without an error: the numbers on screen are old now.
                    if !Task.isCancelled, self?.generation == current {
                        self?.lastError = String(localized: "Mole stopped sending system status. Nora is reconnecting.")
                    }
                } catch {
                    if self?.generation == current { self?.lastError = error.localizedDescription }
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    private func stop() {
        generation += 1
        task?.cancel()
        task = nil
        isStreaming = false
    }

    #if DEBUG
    /// In-memory fixture only: no stream, timers, or process launch.
    func seedVisualSnapshot(_ sample: StatusSnapshot?, error: String? = nil) {
        precondition(task == nil && demand == 0)
        if let sample { ingest(sample); publish() }
        lastError = error
    }
    #endif

    func ingest(_ s: StatusSnapshot) {
        latest = s
        latestAt = Date()
        // Assigning an observed value notifies even when it does not change.
        if lastError != nil { lastError = nil }
        push(&series[0], s.cpu?.usage)
        push(&series[1], s.memory?.usedPercent)
        push(&series[2], s.network.compactMap(\.rxRate).reduce(0, +))
        push(&series[3], s.network.compactMap(\.txRate).reduce(0, +))
        // Mole reports disk I/O already in MB/s (cmd/status/metrics.go); stored as is.
        push(&series[4], s.diskIO?.readRate)
        push(&series[5], s.diskIO?.writeRate)
        if viewers > 0 { publish() }
    }

    private func publish() {
        guard let latest else { return }
        snapshot = latest
        lastSampleAt = latestAt
        (cpu, memory, download, upload, diskRead, diskWrite) = (series[0], series[1], series[2], series[3], series[4], series[5])
    }

    private func push(_ series: inout [Double], _ value: Double?) {
        guard let value, value.isFinite else { return }
        series.append(value)
        if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        // "0 KB", not the formatter's "Zero KB".
        guard value != 0 else { return zero }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static let zero = zeroText(.file)
    private static let zeroMemory = zeroText(.memory)

    private static func zeroText(_ style: ByteCountFormatter.CountStyle) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: 0)
    }

    static func bytes(_ value: Int?) -> String { bytes(value.map(Int64.init)) }

    /// RAM and swap in binary units, so 32 GiB reads "32 GB" as macOS shows it.
    static func memory(_ value: Int64?) -> String {
        guard let value else { return "—" }
        // "0 KB", not "Zero KB" (the quick menu's cache line read "кеш Нуль КБ").
        guard value != 0 else { return zeroMemory }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    /// Megabytes per second, as Mole reports network rates.
    static func rate(_ mbPerSecond: Double?) -> String {
        guard let mbPerSecond else { return "—" }
        let bytes = Int64(mbPerSecond * 1_048_576)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + String(localized: "/s")
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func number(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }
}
