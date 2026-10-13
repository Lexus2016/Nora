import Foundation
import MoleKit
import Observation

/// One `mo status --watch` stream shared by the window and the menu bar. It runs only while
/// something that shows it is visible, and keeps 120 points of history per metric.
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

    static let historyLength = 120

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

    /// Call from `onAppear`; pair with `release()` in `onDisappear`.
    func retain() {
        demand += 1
        stopTask?.cancel()
        if task == nil { start() }
    }

    func release() {
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

    func ingest(_ s: StatusSnapshot) {
        snapshot = s
        lastError = nil
        lastSampleAt = Date()
        push(&cpu, s.cpu?.usage)
        push(&memory, s.memory?.usedPercent)
        let rx = s.network.compactMap(\.rxRate).reduce(0, +)
        let tx = s.network.compactMap(\.txRate).reduce(0, +)
        push(&download, rx)
        push(&upload, tx)
        // Mole reports disk I/O already in MB/s (cmd/status/metrics.go); stored as is.
        push(&diskRead, s.diskIO?.readRate)
        push(&diskWrite, s.diskIO?.writeRate)
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
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func bytes(_ value: Int?) -> String { bytes(value.map(Int64.init)) }

    /// RAM and swap in binary units, so 32 GiB reads "32 GB" as macOS shows it.
    static func memory(_ value: Int64?) -> String {
        guard let value else { return "—" }
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
