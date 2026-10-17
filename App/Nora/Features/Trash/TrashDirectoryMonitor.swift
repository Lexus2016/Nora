import AppKit
import CoreServices
import Darwin
import Foundation

@MainActor
protocol TrashDirectoryMonitoring: AnyObject {
    /// Event streams are hints. Their callback never recursively reads the directory.
    func start(onChange: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void)
    func stop()
    /// One lstat only; returns true if root identity, root metadata, or availability changed.
    func sampleRoot() -> Bool
}

/// Watches only the current user's home Trash. No external-volume Trash or launch agent.
/// FSEvents catches descendant writes; the 10-second fallback in the model only probes the root.
@MainActor
final class TrashDirectoryMonitor: TrashDirectoryMonitoring {
    private let root: URL
    private var stream: FSEventStreamRef?
    private var relay: TrashEventRelay?
    private var wakeObserver: NSObjectProtocol?
    private var lastProbe: Probe?
    private var onChange: (@MainActor () -> Void)?

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)) {
        self.root = root
    }

    func start(onChange: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        lastProbe = probe()
        bindStream()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in onWake() } }
    }

    func stop() {
        unbindStream()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        onChange = nil
        lastProbe = nil
    }

    func sampleRoot() -> Bool {
        let next = probe()
        let previous = lastProbe
        lastProbe = next
        let changed = previous != next
        // Root recreation, a lost stream, and permission recovery get a fresh binding.
        if stream == nil || previous?.identity != next.identity { bindStream() }
        return changed
    }

    private func bindStream() {
        unbindStream()
        guard let onChange else { return }
        let relay = TrashEventRelay { Task { @MainActor in onChange() } }
        self.relay = relay
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(relay).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TrashEventRelay>.fromOpaque(info).takeUnretainedValue().fire()
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            self.relay = nil
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.relay = nil
            return
        }
        self.stream = stream
    }

    private func unbindStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        relay = nil
    }

    private struct Probe: Equatable {
        let identity: String
        let metadata: String
    }

    private func probe() -> Probe {
        var value = stat()
        guard lstat(root.path, &value) == 0 else {
            return Probe(identity: "unavailable:\(errno)", metadata: "")
        }
        return Probe(identity: "\(value.st_dev):\(value.st_ino):\(value.st_mode)",
                     metadata: "\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)")
    }

}

private final class TrashEventRelay: Sendable {
    private let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func fire() { callback() }
}

/// No filesystem access, event stream, wake observer, or real-home lookup in rendering/test hosts.
@MainActor
final class InertTrashDirectoryMonitor: TrashDirectoryMonitoring {
    func start(onChange: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {}
    func stop() {}
    func sampleRoot() -> Bool { false }
}
