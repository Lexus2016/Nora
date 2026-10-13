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
    private(set) var isStreaming = false

    static let historyLength = 120

    @ObservationIgnored private var mole: Mole?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    func attach(_ mole: Mole) {
        self.mole = mole
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
        task = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    for try await snapshot in StatusStream.snapshots(mole) {
                        self?.ingest(snapshot)
                        delay = 1
                    }
                } catch {
                    self?.lastError = error.localizedDescription
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    private func ingest(_ s: StatusSnapshot) {
        snapshot = s
        lastError = nil
        push(&cpu, s.cpu?.usage)
        push(&memory, s.memory?.usedPercent)
        let rx = s.network.compactMap(\.rxRate).reduce(0, +)
        let tx = s.network.compactMap(\.txRate).reduce(0, +)
        push(&download, rx)
        push(&upload, tx)
        push(&diskRead, s.diskIO?.readRate.map { $0 / 1_048_576 })
        push(&diskWrite, s.diskIO?.writeRate.map { $0 / 1_048_576 })
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
