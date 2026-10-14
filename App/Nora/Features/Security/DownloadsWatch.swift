import Foundation
import MoleKit

/// Watches a folder for new files. A directory event starts the check; a file is handed over once its
/// name has no partial-download suffix and its size is unchanged across two checks.
///
/// A file is known by its version (file number, size, modification date), not its name: a file
/// deleted and downloaded again under the same name, or replaced, is a new arrival and is checked
/// again. While a check is pending the listing is compared on every poll, so a file that grows
/// after it was handed over is handed over again once it settles.
@MainActor
final class DownloadsWatch {
    struct Version: Equatable {
        let file: UInt64
        let size: Int64
        let modified: Date?
    }

    private struct Pending {
        var size: Int64
        var stableChecks: Int
    }

    private static let partialSuffixes = [".download", ".crdownload", ".part"]

    private let directory: URL
    private let onReady: @MainActor (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    /// The version of each name last seen settled: present at the start, handed over, or a folder.
    private var known: [String: Version] = [:]
    private var pending: [String: Pending] = [:]
    private var pollTask: Task<Void, Never>?

    init(directory: URL, onReady: @escaping @MainActor (URL) -> Void) {
        self.directory = directory
        self.onReady = onReady
    }

    /// Files that already exist when the watch starts are not scanned; only new arrivals are.
    func start() throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw SecurityError.cannotWatch(directory.path) }
        known = Dictionary(uniqueKeysWithValues: listing().compactMap { name in version(of: name).map { (name, $0) } })
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.directoryChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        pollTask?.cancel()
        pollTask = nil
        pending = [:]
    }

    private func directoryChanged() {
        let names = Set(listing())
        // A name that is gone and comes back is a new file.
        for name in known.keys where !names.contains(name) { known[name] = nil }
        for name in names where pending[name] == nil && !name.hasPrefix(".") && !Self.isPartial(name) {
            guard let current = version(of: name), known[name] != current else { continue }
            if Self.isDirectory(directory.appendingPathComponent(name)) {
                known[name] = current
                continue
            }
            pending[name] = Pending(size: -1, stableChecks: 0)
        }
        if !pending.isEmpty { startPolling() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.checkPending()
                self.directoryChanged()
                if self.pending.isEmpty {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    private func checkPending() {
        for name in pending.keys.sorted() {
            guard var state = pending[name] else { continue }
            let url = directory.appendingPathComponent(name)
            guard let size = Self.size(of: url) else {
                // Renamed or removed while downloading. A renamed file shows up again under its new name.
                pending[name] = nil
                continue
            }
            if size == state.size {
                state.stableChecks += 1
            } else {
                state.size = size
                state.stableChecks = 0
            }
            if state.stableChecks >= 1 {
                pending[name] = nil
                known[name] = version(of: name)
                onReady(url)
            } else {
                pending[name] = state
            }
        }
    }

    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func version(of name: String) -> Version? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Version(file: file.uint64Value, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                       modified: attributes[.modificationDate] as? Date)
    }

    private static func isPartial(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return partialSuffixes.contains { lowercased.hasSuffix($0) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}

/// A `clamd` child process that lives only while the Downloads watch is on. Scans use `clamdscan` against it.
@MainActor
final class ClamdSession {
    private let clamd: URL
    private let clamdscan: URL
    private let layout: ClamAVLayout
    private var process: Process?
    /// Called when clamd exits, whether it crashed or was stopped. Set before `start()`.
    var onExit: (@MainActor () -> Void)?

    init(clamd: URL, clamdscan: URL, layout: ClamAVLayout) {
        self.clamd = clamd
        self.clamdscan = clamdscan
        self.layout = layout
    }

    /// Starts clamd in the foreground and waits until its socket appears (the database is loaded by then).
    func start() async throws {
        let process = Process()
        process.executableURL = clamd
        process.arguments = ["--foreground", "--config-file", layout.clamdConfig.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        let onExit = self.onExit
        process.terminationHandler = { finished in
            ChildProcesses.unregister(finished)
            Task { @MainActor in onExit?() }
        }
        // A socket left by an earlier clamd would look like readiness of this one.
        try? FileManager.default.removeItem(at: layout.socket)
        ChildProcesses.register(process)
        do { try process.run() } catch {
            ChildProcesses.unregister(process)
            throw error
        }
        self.process = process
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: layout.socket.path) { return }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        stop()
        throw SecurityError.clamdDidNotStart
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func scanCommand(for file: URL) -> ShellCommand {
        ShellCommand(clamdscan.path, ["--config-file", layout.clamdConfig.path, "--infected", "--no-summary", "--fdpass", file.path])
    }

    func stop() {
        if let process {
            if process.isRunning { process.terminate() }
            ChildProcesses.unregister(process)
        }
        process = nil
    }
}
