import AppKit
import CoreServices
import Darwin
import Foundation
import MoleKit

@MainActor
protocol TrashDirectoryMonitoring: AnyObject {
    /// Event streams are hints. Their callback never recursively reads the directory.
    func start(onChange: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void)
    func stop()
    /// One lstat per watched root; returns true if a root identity, root metadata, availability,
    /// or the set of mounted Trash roots changed.
    func sampleRoot() -> Bool
}

/// Watches the current user's home Trash and the per-user Trash of every mounted disk.
/// Mount and unmount notifications rebind the streams; the 10-second fallback in the model
/// probes only root metadata, never a subtree.
@MainActor
final class TrashDirectoryMonitor: TrashDirectoryMonitoring {
    private let rootProvider: (@MainActor () -> [URL])?
    private var roots: [URL]
    private var watches: [String: Watch] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var mountObservers: [NSObjectProtocol] = []
    private var lastProbe: [String: Probe] = [:]
    private var onChange: (@MainActor () -> Void)?

    private struct Watch {
        let stream: FSEventStreamRef
        let relay: TrashEventRelay
    }

    /// A fixed root for a synthetic fixture: no volume discovery, no mount observers.
    init(root: URL) {
        roots = [root]
        rootProvider = nil
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        roots = [home] + TrashLocations.mounted().map(\.rootURL)
        rootProvider = { [home] in [home] + TrashLocations.mounted().map(\.rootURL) }
    }

    func start(onChange: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        for root in roots { lastProbe[root.path] = probe(root) }
        bindStreams()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in onWake() } }
        guard rootProvider != nil else { return }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            mountObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.mountedRootsChanged() } })
        }
    }

    func stop() {
        unbindStreams()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        for observer in mountObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        mountObservers = []
        onChange = nil
        lastProbe = [:]
    }

    func sampleRoot() -> Bool {
        guard onChange != nil else { return false }
        var changed = false
        if let rootProvider {
            let next = rootProvider()
            if next.map(\.path) != roots.map(\.path) {
                roots = next
                changed = true
                bindStreams()
            }
        }
        var identityChanged = false
        for root in roots {
            let value = probe(root)
            let previous = lastProbe[root.path]
            lastProbe[root.path] = value
            if previous != value {
                changed = true
                if previous?.identity != value.identity { identityChanged = true }
            }
        }
        if identityChanged || watches.count != roots.count { bindStreams() }
        return changed
    }

    /// A disk appeared or left: watch the new set and tell the model, so a Trash on a just-mounted
    /// disk is reviewed without waiting for the fallback tick.
    private func mountedRootsChanged() {
        guard let rootProvider else { return }
        let next = rootProvider()
        guard next.map(\.path) != roots.map(\.path) else { return }
        roots = next
        for root in roots { lastProbe[root.path] = probe(root) }
        bindStreams()
        onChange?()
    }

    private func bindStreams() {
        unbindStreams()
        guard let onChange else { return }
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let relay = TrashEventRelay { Task { @MainActor in onChange() } }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(relay).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<TrashEventRelay>.fromOpaque(info).takeUnretainedValue().fire()
            }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
                continue
            }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                continue
            }
            watches[root.path] = Watch(stream: stream, relay: relay)
        }
    }

    private func unbindStreams() {
        for watch in watches.values {
            FSEventStreamStop(watch.stream)
            FSEventStreamInvalidate(watch.stream)
            FSEventStreamRelease(watch.stream)
        }
        watches = [:]
    }

    private struct Probe: Equatable {
        let identity: String
        let metadata: String
    }

    private func probe(_ root: URL) -> Probe {
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
