import CPTYShim
import Darwin
import Foundation

/// Snapshot-scoped deletion for the current user's home .Trash. Never invokes Mole, Finder,
/// a shell, recursive removeItem, or a copy/delete fallback. Call off the main actor.
///
/// The caller must present this snapshot and obtain explicit permanent-deletion confirmation
/// before execute. A later scan does not silently replace that reviewed snapshot.
///
/// Threat boundary: private staging and capture-before-unlink reduce pathname races, but POSIX
/// has no atomic compare-and-unlink. Another process with the same UID, or an open writable file
/// descriptor, can still mutate an object. This is metadata identity protection, not a content
/// lock. The result deliberately reports entry counts, never exact reclaimed disk bytes.
public final class HomeTrashService: @unchecked Sendable {
    private let home: URL
    private let owner: UInt32
    private let limits: TrashScanLimits
    private let transition: (TrashTransition) throws -> Void
    private let lock = NSLock()
    private let recoveryComponents = ["Library", "Application Support", "Nora", "TrashRecovery"]

    public init() {
        home = FileManager.default.homeDirectoryForCurrentUser
        owner = UInt32(geteuid())
        limits = TrashScanLimits()
        transition = { _ in }
    }

    /// Synthetic fixture homes only. Not public API, and never based on $HOME in tests.
    init(fixtureHome: URL, limits: TrashScanLimits = TrashScanLimits(),
         transition: @escaping (TrashTransition) throws -> Void = { _ in }) {
        home = fixtureHome
        owner = UInt32(geteuid())
        self.limits = limits
        self.transition = transition
    }

    private var recoveryURL: URL {
        recoveryComponents.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    public func scan(cancellation: TrashCancellationToken = TrashCancellationToken()) throws -> TrashSnapshot {
        try lock.withLock { try scanUnlocked(cancellation) }
    }

    public func recoveryStatus() -> TrashRecoveryStatus {
        lock.withLock { statusUnlocked() }
    }

    /// Recovery only returns remaining captured objects, without overwriting existing names.
    /// It NEVER continues permanent deletion, including after an interrupted delete intent.
    public func recover() -> TrashRecoveryStatus {
        lock.withLock {
            do {
                let homeFD = try openHome()
                guard let recovery = try openRecovery(homeFD, create: false) else { return clearStatus }
                let heldLock = try TrashDirectory(nora_trash_lock(recovery.descriptor), operation: "lock recovery")
                defer { withExtendedLifetime(heldLock) {} }
                for name in try runNames(recovery) {
                    let run = try openPrivate(name, in: recovery, device: try TrashFS.identity(homeFD).device)
                    if try reconcileMetadataOnlyRun(name, run: run, recovery: recovery) { continue }
                    var journal = try loadJournal(run, name: name)
                    try restore(&journal, run: run, homeFD: homeFD)
                    try finishRun(journal, run: run, recovery: recovery)
                }
                return clearStatus
            } catch { return blockedStatus(error.localizedDescription) }
        }
    }

    public func execute(_ snapshot: TrashSnapshot,
                        cancellation: TrashCancellationToken = TrashCancellationToken()) -> TrashExecutionResult {
        lock.withLock { executeUnlocked(snapshot, cancellation) }
    }

    private var clearStatus: TrashRecoveryStatus {
        TrashRecoveryStatus(blocksNewRun: false, message: "No Trash recovery is pending.", recoveryDirectoryURL: nil)
    }
    private func blockedStatus(_ message: String) -> TrashRecoveryStatus {
        TrashRecoveryStatus(blocksNewRun: true, message: message, recoveryDirectoryURL: recoveryURL)
    }
    private func statusUnlocked() -> TrashRecoveryStatus {
        do {
            let homeFD = try openHome()
            guard let recovery = try openRecovery(homeFD, create: false) else { return clearStatus }
            let names = try runNames(recovery)
            guard !names.isEmpty else { return clearStatus }
            // Decode every journal; malformed, missing, or unreadable records still block new work.
            for name in names {
                let run = try openPrivate(name, in: recovery, device: try TrashFS.identity(homeFD).device)
                if try isMetadataOnlyRun(run) { continue }
                _ = try loadJournal(run, name: name)
            }
            return blockedStatus("An interrupted Trash operation needs recovery. Remaining items are preserved.")
        } catch { return blockedStatus(error.localizedDescription) }
    }

    private func openHome() throws -> TrashDirectory {
        let directory = try TrashFS.open(home)
        let identity = try TrashFS.identity(directory)
        guard identity.type == .directory, identity.ownerID == owner, identity.mode & 0o022 == 0 else {
            throw TrashSafetyError.unavailable("home directory ownership could not be verified")
        }
        try TrashFS.requireNoGrantACL(directory)
        return directory
    }
    private func openTrash(_ homeFD: TrashDirectory) throws -> TrashDirectory {
        let directory = try TrashFS.open(".Trash", in: homeFD)
        let identity = try TrashFS.identity(directory)
        guard identity.type == .directory, identity.ownerID == owner,
              identity.device == (try TrashFS.identity(homeFD)).device else {
            throw TrashSafetyError.unavailable("Trash ownership or filesystem could not be verified")
        }
        return directory
    }
    private func verifyTrash(_ directory: TrashDirectory, homeFD: TrashDirectory,
                             expected: TrashFileIdentity) throws {
        guard expected.sameObject(as: try TrashFS.identity(directory)),
              expected.sameObject(as: try TrashFS.identity(".Trash", in: homeFD)) else {
            throw TrashSafetyError.changed("the Trash directory was replaced")
        }
    }
    private func openPrivate(_ name: String, in parent: TrashDirectory, device: UInt64) throws -> TrashDirectory {
        let directory = try TrashFS.open(name, in: parent)
        let identity = try TrashFS.identity(directory)
        guard identity.ownerID == owner, identity.device == device, identity.mode & 0o077 == 0 else {
            throw TrashSafetyError.recoveryRequired("recovery directory ownership, mode or filesystem changed")
        }
        try TrashFS.requireNoACL(directory)
        return directory
    }
    private func openRecovery(_ homeFD: TrashDirectory, create: Bool) throws -> TrashDirectory? {
        var parent = homeFD
        let device = try TrashFS.identity(homeFD).device
        for (index, name) in recoveryComponents.enumerated() {
            if try TrashFS.optionalIdentity(name, in: parent) == nil {
                guard create else { return nil }
                parent = try TrashFS.make(name, in: parent)
            } else {
                parent = try TrashFS.open(name, in: parent)
            }
            let identity = try TrashFS.identity(parent)
            guard identity.ownerID == owner, identity.device == device,
                  (index < 3 ? identity.mode & 0o022 == 0 : identity.mode & 0o077 == 0) else {
                throw TrashSafetyError.recoveryRequired("private same-filesystem staging is unavailable")
            }
            if index == 3 { try TrashFS.requireNoACL(parent) }
            else { try TrashFS.requireNoGrantACL(parent) }
        }
        return parent
    }
    private func runNames(_ directory: TrashDirectory) throws -> [String] {
        let names = try TrashFS.names(directory, maximum: 128)
        return try names.filter { $0 != ".lock" }.map {
            guard $0.hasPrefix("run-"), UUID(uuidString: String($0.dropFirst(4))) != nil else {
                throw TrashSafetyError.recoveryRequired("unrecognized recovery entry")
            }
            return $0
        }
    }

    private struct ScanBudget {
        var count = 0
        var pathBytes = 0
        var logicalBytes: UInt64 = 0
        let deadline: TimeInterval
    }
    private func checkBudget(_ budget: ScanBudget, cancellation: TrashCancellationToken) throws {
        try cancellation.check()
        guard budget.count <= limits.maximumEntries, budget.pathBytes <= limits.maximumPathBytes,
              ProcessInfo.processInfo.systemUptime < budget.deadline else {
            throw TrashSafetyError.incomplete("scan limits were reached")
        }
    }
    private func scanUnlocked(_ cancellation: TrashCancellationToken) throws -> TrashSnapshot {
        try cancellation.check()
        let homeFD = try openHome()
        let root = try openTrash(homeFD)
        let identity = try TrashFS.identity(root)
        var budget = ScanBudget(deadline: ProcessInfo.processInfo.systemUptime + limits.timeout)
        var entries: [TrashSnapshotEntry] = []
        try scanDirectory(root, path: "", device: identity.device, depth: 0,
                          budget: &budget, entries: &entries, cancellation: cancellation)
        try verifyTrash(root, homeFD: homeFD, expected: identity)
        guard identity == (try TrashFS.identity(root)) else { throw TrashSafetyError.changed("during scan") }
        return TrashSnapshot(id: UUID(), scannedAt: Date(), rootIdentity: identity,
                             entries: entries.sorted { $0.relativePath < $1.relativePath },
                             estimatedLogicalBytes: budget.logicalBytes)
    }
    private func scanDirectory(_ directory: TrashDirectory, path: String, device: UInt64, depth: Int,
                               budget: inout ScanBudget, entries: inout [TrashSnapshotEntry],
                               cancellation: TrashCancellationToken) throws {
        try checkBudget(budget, cancellation: cancellation)
        guard depth <= limits.maximumDepth else { throw TrashSafetyError.incomplete("directory nesting limit") }
        let before = try TrashFS.identity(directory)
        try transition(.scanning(path))
        let names = try TrashFS.names(directory, maximum: limits.maximumEntries)
        for name in names {
            try checkBudget(budget, cancellation: cancellation)
            let relative = path.isEmpty ? name : path + "/" + name
            let identity = try TrashFS.identity(name, in: directory)
            guard identity.device == device, identity.ownerID == owner else {
                throw TrashSafetyError.incomplete("mount crossing or unsupported ownership")
            }
            budget.count += 1
            budget.pathBytes += relative.utf8.count
            if identity.type != .directory {
                let (value, overflow) = budget.logicalBytes.addingReportingOverflow(identity.size)
                guard !overflow else { throw TrashSafetyError.incomplete("size overflow") }
                budget.logicalBytes = value
            }
            try checkBudget(budget, cancellation: cancellation)
            entries.append(TrashSnapshotEntry(relativePath: relative, identity: identity))
            if identity.type == .directory {
                let child = try TrashFS.open(name, in: directory)
                guard identity == (try TrashFS.identity(child)) else { throw TrashSafetyError.changed(relative) }
                try scanDirectory(child, path: relative, device: device, depth: depth + 1,
                                  budget: &budget, entries: &entries, cancellation: cancellation)
            }
            guard identity == (try TrashFS.identity(name, in: directory)) else {
                throw TrashSafetyError.changed(relative)
            }
        }
        guard before == (try TrashFS.identity(directory)), names == (try TrashFS.names(directory, maximum: limits.maximumEntries)) else {
            throw TrashSafetyError.changed(path.isEmpty ? "Trash contents" : path)
        }
    }

    private struct Top: Codable {
        let original: String
        let slot: String
        let identity: TrashFileIdentity
    }
    private struct Capture: Codable {
        let entryIndex: Int
        let candidate: String
        var deleting: Bool = false
    }
    private struct Manifest: Codable {
        let version: Int
        let name: String
        let root: TrashFileIdentity
        let snapshot: TrashSnapshot
        let tops: [Top]
    }
    private struct Progress: Codable {
        let version: Int
        let name: String
        var phase: String
        var capture: Capture?
        var deletedEntryCount: Int
    }
    private struct Journal {
        let manifest: Manifest
        var progress: Progress
        var name: String { manifest.name }
        var root: TrashFileIdentity { manifest.root }
        var snapshot: TrashSnapshot { manifest.snapshot }
        var tops: [Top] { manifest.tops }
        var phase: String {
            get { progress.phase }
            set { progress.phase = newValue }
        }
        var capture: Capture? {
            get { progress.capture }
            set { progress.capture = newValue }
        }
    }
    private func save(_ journal: Journal, run: TrashDirectory) throws {
        try transition(.beforeJournal(journal.phase))
        // The complete manifest is immutable and written once. Each write-ahead progress
        // record has bounded size regardless of the number of reviewed entries.
        try TrashFS.write(journal.progress, in: run)
        try transition(.afterJournal(journal.phase))
    }
    private func loadJournal(_ run: TrashDirectory, name: String) throws -> Journal {
        let manifest = try TrashFS.read(Manifest.self, name: "manifest.json", in: run)
        let progress = try TrashFS.read(Progress.self, in: run)
        let journal = Journal(manifest: manifest, progress: progress)
        let paths = journal.snapshot.entries.map(\.relativePath)
        guard manifest.version == 1, progress.version == 1, progress.name == name,
              journal.name == name, journal.snapshot.rootIdentity == journal.root,
              journal.root.ownerID == owner, paths.count <= limits.maximumEntries,
              paths.allSatisfy(TrashFS.validPath), Set(paths).count == paths.count,
              progress.deletedEntryCount >= 0, progress.deletedEntryCount <= paths.count,
              ["staging", "validated", "capturing", "deleting", "restoring", "finished"].contains(journal.phase),
              journal.tops.count == journal.snapshot.topLevelItemCount else {
            throw TrashSafetyError.recoveryRequired("malformed recovery journal")
        }
        let expectedTops = journal.snapshot.entries.filter { !$0.relativePath.contains("/") }
        for (index, top) in journal.tops.enumerated() {
            guard top.slot == "item-\(index)", top.original == expectedTops[index].relativePath,
                  top.identity == expectedTops[index].identity else {
                throw TrashSafetyError.recoveryRequired("malformed staging map")
            }
        }
        if let capture = journal.capture {
            guard paths.indices.contains(capture.entryIndex), capture.candidate == "entry-\(capture.entryIndex)" else {
                throw TrashSafetyError.recoveryRequired("malformed candidate record")
            }
        }
        return journal
    }

    private func executeUnlocked(_ snapshot: TrashSnapshot, _ cancellation: TrashCancellationToken) -> TrashExecutionResult {
        var run: TrashDirectory?
        var recovery: TrashDirectory?
        var homeFD: TrashDirectory?
        var journal: Journal?
        var heldLock: TrashDirectory?
        var deletedCount = 0
        defer { withExtendedLifetime(heldLock) {} }
        do {
            try cancellation.check()
            let openedHome = try openHome()
            homeFD = openedHome
            guard let staging = try openRecovery(openedHome, create: true) else {
                throw TrashSafetyError.recoveryRequired("staging unavailable")
            }
            recovery = staging
            heldLock = try TrashDirectory(nora_trash_lock(staging.descriptor), operation: "lock Trash operation")
            guard try runNames(staging).isEmpty else { throw TrashSafetyError.recoveryRequired("an earlier operation is unresolved") }
            let fresh = try scanUnlocked(cancellation)
            guard snapshot.matchesContents(of: fresh) else { throw TrashSafetyError.changed("since review") }
            if snapshot.entries.isEmpty { return result(.completed, count: 0, "The reviewed Trash was empty.") }
            let root = try openTrash(openedHome)
            try verifyTrash(root, homeFD: openedHome, expected: snapshot.rootIdentity)
            let name = "run-\(UUID().uuidString)"
            let batch = try TrashFS.make(name, in: staging)
            run = batch
            let tops = snapshot.entries.filter { !$0.relativePath.contains("/") }.enumerated().map {
                Top(original: $0.element.relativePath, slot: "item-\($0.offset)", identity: $0.element.identity)
            }
            var current = Journal(manifest: Manifest(version: 1, name: name, root: snapshot.rootIdentity,
                                                      snapshot: snapshot, tops: tops),
                                  progress: Progress(version: 1, name: name, phase: "staging",
                                                     capture: nil, deletedEntryCount: 0))
            journal = current
            try TrashFS.requireNoACL(batch)
            try TrashFS.write(current.manifest, name: "manifest.json", in: batch)
            try save(current, run: batch)
            let items = try TrashFS.make("items", in: batch)
            let candidates = try TrashFS.make("candidates", in: batch)
            try TrashFS.requireNoACL(items)
            try TrashFS.requireNoACL(candidates)
            var stagedIdentities: [String: TrashFileIdentity] = [:]
            for (index, top) in tops.enumerated() {
                try cancellation.check()
                try save(current, run: batch) // write-ahead intent before every move
                try transition(.beforeStage(index))
                try verifyTrash(root, homeFD: openedHome, expected: snapshot.rootIdentity)
                guard top.identity == (try TrashFS.identity(top.original, in: root)) else {
                    throw TrashSafetyError.changed(top.original)
                }
                try TrashFS.move(top.original, from: root, to: items, as: top.slot)
                let stagedIdentity = try TrashFS.identity(top.slot, in: items)
                guard top.identity.matchesAfterRename(stagedIdentity) else {
                    throw TrashSafetyError.changed(top.original)
                }
                stagedIdentities[top.original] = stagedIdentity
                try transition(.afterStage(index))
            }
            // All reviewed top-level entries must be captured and the ENTIRE manifest must
            // still match before the first unlink. New arrivals in .Trash are never included.
            try validateStaged(current, items: items, expectedTops: stagedIdentities, cancellation: cancellation)
            current.phase = "validated"
            journal = current
            try save(current, run: batch)
            let order = snapshot.entries.indices.sorted {
                let lhs = snapshot.entries[$0].relativePath.split(separator: "/").count
                let rhs = snapshot.entries[$1].relativePath.split(separator: "/").count
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }
            for index in order {
                try cancellation.check()
                let entry = snapshot.entries[index]
                let candidate = "entry-\(index)"
                current.phase = "capturing"
                current.capture = Capture(entryIndex: index, candidate: candidate)
                journal = current
                try save(current, run: batch)
                let source = try sourceParent(entry, journal: current, items: items)
                try transition(.beforeCapture(index))
                try verifySourceParent(source.directory, entry: entry, journal: current, items: items)
                let before = try TrashFS.identity(source.name, in: source.directory)
                let expected = stagedIdentities[entry.relativePath] ?? entry.identity
                guard entry.identity.sameObject(as: before),
                      entry.type == .directory || expected == before else {
                    throw TrashSafetyError.changed(entry.relativePath)
                }
                if entry.type == .directory, !(try TrashFS.names(try TrashFS.open(source.name, in: source.directory))).isEmpty {
                    throw TrashSafetyError.changed("unexpected nested item in \(entry.relativePath)")
                }
                try TrashFS.move(source.name, from: source.directory, to: candidates, as: candidate)
                let captured = try TrashFS.identity(candidate, in: candidates)
                guard entry.identity.sameObject(as: captured),
                      entry.type == .directory || entry.identity.matchesAfterRename(captured) else {
                    throw TrashSafetyError.changed("captured candidate \(entry.relativePath)")
                }
                try transition(.afterCapture(index))
                current.phase = "deleting"
                current.capture?.deleting = true
                journal = current
                try save(current, run: batch)
                try cancellation.check()
                try transition(.beforeDelete(index))
                guard captured == (try TrashFS.identity(candidate, in: candidates)) else {
                    throw TrashSafetyError.changed("candidate changed before deletion")
                }
                // Only this private candidate name is unlinked. rmdir rejects non-empty dirs.
                try TrashFS.unlink(candidate, in: candidates, directory: entry.type == .directory)
                deletedCount += 1
                try transition(.afterUnlink(index))
                try transition(.beforeRemovalSync(index))
                try TrashFS.sync(candidates)
                try transition(.afterDelete(index))
                current.progress.deletedEntryCount = deletedCount
                current.capture = nil
                current.phase = "validated"
                journal = current
                try save(current, run: batch)
            }
            current.phase = "finished"
            journal = current
            try save(current, run: batch)
            try finishRun(current, run: batch, recovery: staging)
            return result(.completed, count: deletedCount, "The reviewed Trash entries were permanently deleted. New arrivals were left alone.")
        } catch {
            // A crash injection models abrupt process death: do not perform implicit recovery.
            if error is TrashInjectedFailure { return result(.recoveryRequired, count: deletedCount, "Interrupted operation preserved for recovery.", recovery: true) }
            if var current = journal, let run, let recovery, let homeFD {
                if current.phase == "finished" {
                    // Never recreate a journal after final metadata removal has begun. An
                    // empty/manifest-only orphan is reconciled by recover() without deletion.
                    return result(.recoveryRequired, count: deletedCount,
                                  "Payload work finished; recovery metadata cleanup is pending: \(error.localizedDescription)", recovery: true)
                }
                do {
                    try restore(&current, run: run, homeFD: homeFD)
                    try finishRun(current, run: run, recovery: recovery)
                } catch {
                    return result(.recoveryRequired, count: deletedCount,
                                  "Remaining items were preserved. Recovery stopped: \(error.localizedDescription)", recovery: true)
                }
            }
            let pending = statusUnlocked()
            if pending.blocksNewRun { return result(.recoveryRequired, count: deletedCount, pending.message, recovery: true) }
            if error is CancellationError { return result(.cancelled, count: deletedCount, "Cancelled. Remaining entries were restored or preserved.") }
            if case TrashSafetyError.changed = error { return result(.requiresNewReview, count: deletedCount, error.localizedDescription) }
            return result(.failed, count: deletedCount, error.localizedDescription)
        }
    }
    private func result(_ status: TrashExecutionStatus, count: Int, _ message: String, recovery: Bool = false) -> TrashExecutionResult {
        TrashExecutionResult(status: status, deletedEntryCount: count, message: message,
                             recoveryDirectoryURL: recovery ? recoveryURL : nil)
    }

    private func validateStaged(_ journal: Journal, items: TrashDirectory,
                                expectedTops: [String: TrashFileIdentity],
                                cancellation: TrashCancellationToken) throws {
        guard try TrashFS.names(items) == journal.tops.map(\.slot).sorted() else {
            throw TrashSafetyError.changed("staging membership")
        }
        var captured: [TrashSnapshotEntry] = []
        var budget = ScanBudget(deadline: ProcessInfo.processInfo.systemUptime + limits.timeout)
        for top in journal.tops {
            try cancellation.check()
            let identity = try TrashFS.identity(top.slot, in: items)
            guard expectedTops[top.original] == identity else { throw TrashSafetyError.changed(top.original) }
            // Normalize only ctime of the top-level object, changed by our own rename.
            captured.append(TrashSnapshotEntry(relativePath: top.original, identity: top.identity))
            if identity.type == .directory {
                let child = try TrashFS.open(top.slot, in: items)
                guard identity == (try TrashFS.identity(child)) else { throw TrashSafetyError.changed(top.original) }
                try scanDirectory(child, path: top.original, device: journal.root.device, depth: 1,
                                  budget: &budget, entries: &captured, cancellation: cancellation)
                guard identity == (try TrashFS.identity(top.slot, in: items)) else { throw TrashSafetyError.changed(top.original) }
            }
        }
        guard captured.sorted(by: { $0.relativePath < $1.relativePath }) == journal.snapshot.entries else {
            throw TrashSafetyError.changed("staged contents differ from the review")
        }
    }
    private func sourceParent(_ entry: TrashSnapshotEntry, journal: Journal, items: TrashDirectory) throws -> (directory: TrashDirectory, name: String) {
        let components = entry.relativePath.split(separator: "/").map(String.init)
        guard let first = components.first, let top = journal.tops.first(where: { $0.original == first }) else {
            throw TrashSafetyError.recoveryRequired("invalid original path")
        }
        if components.count == 1 { return (items, top.slot) }
        var parent = try TrashFS.open(top.slot, in: items)
        guard top.identity.sameObject(as: try TrashFS.identity(parent)) else { throw TrashSafetyError.changed(first) }
        var relative = first
        for name in components.dropFirst().dropLast() {
            relative += "/" + name
            guard let expected = journal.snapshot.entries.first(where: { $0.relativePath == relative }) else {
                throw TrashSafetyError.recoveryRequired("missing parent identity")
            }
            parent = try TrashFS.open(name, in: parent)
            guard expected.type == .directory, expected.identity.sameObject(as: try TrashFS.identity(parent)) else {
                throw TrashSafetyError.changed(relative)
            }
        }
        return (parent, components.last!)
    }
    private func verifySourceParent(_ held: TrashDirectory, entry: TrashSnapshotEntry, journal: Journal,
                                    items: TrashDirectory) throws {
        let reopened = try sourceParent(entry, journal: journal, items: items)
        guard (try TrashFS.identity(held)).sameObject(as: try TrashFS.identity(reopened.directory)) else {
            throw TrashSafetyError.changed("held parent directory was replaced")
        }
    }

    private func restore(_ journal: inout Journal, run: TrashDirectory, homeFD: TrashDirectory) throws {
        let root = try openTrash(homeFD)
        try verifyTrash(root, homeFD: homeFD, expected: journal.root)
        journal.phase = "restoring"
        try save(journal, run: run)
        // A crash may occur between journal creation and staging-directory creation.
        let items = try TrashFS.optionalIdentity("items", in: run) == nil ? nil :
            try openPrivate("items", in: run, device: journal.root.device)
        let candidates = try TrashFS.optionalIdentity("candidates", in: run) == nil ? nil :
            try openPrivate("candidates", in: run, device: journal.root.device)
        if let candidates {
            let names = try TrashFS.names(candidates)
            guard names.allSatisfy({ $0 == journal.capture?.candidate }) else {
                throw TrashSafetyError.recoveryRequired("unrecognized captured object; preserved for manual recovery")
            }
            if let capture = journal.capture, let identity = try TrashFS.optionalIdentity(capture.candidate, in: candidates) {
                let entry = journal.snapshot.entries[capture.entryIndex]
                guard let items, entry.identity.sameObject(as: identity) else {
                    throw TrashSafetyError.recoveryRequired("candidate identity changed; preserved for manual recovery")
                }
                let source = try sourceParent(entry, journal: journal, items: items)
                try transition(.beforeRestore(entry.relativePath))
                try verifySourceParent(source.directory, entry: entry, journal: journal, items: items)
                try save(journal, run: run)
                try TrashFS.move(capture.candidate, from: candidates, to: source.directory, as: source.name)
                try transition(.afterRestore(entry.relativePath))
            }
            // An absent candidate after a deleting intent may already have been unlinked.
            // Never repeat that deletion or infer that its original name should be removed.
        }
        journal.capture = nil
        try save(journal, run: run)
        if let items {
            let names = try TrashFS.names(items)
            guard names.allSatisfy({ slot in journal.tops.contains { $0.slot == slot } }) else {
                throw TrashSafetyError.recoveryRequired("unrecognized staged object; preserved")
            }
            var collision = false
            for top in journal.tops {
                guard let identity = try TrashFS.optionalIdentity(top.slot, in: items) else { continue }
                guard top.identity.sameObject(as: identity) else {
                    throw TrashSafetyError.recoveryRequired("staged identity changed; preserved")
                }
                try transition(.beforeRestore(top.original))
                try verifyTrash(root, homeFD: homeFD, expected: journal.root)
                if try TrashFS.optionalIdentity(top.original, in: root) != nil { collision = true; continue }
                try save(journal, run: run)
                try TrashFS.move(top.slot, from: items, to: root, as: top.original)
                try transition(.afterRestore(top.original))
            }
            if collision { throw TrashSafetyError.recoveryRequired("an original Trash name is occupied; remaining items are in \(recoveryURL.path)") }
        }
        journal.phase = "finished"
        try save(journal, run: run)
    }
    private func finishRun(_ journal: Journal, run: TrashDirectory, recovery: TrashDirectory) throws {
        // Only app-created journal/empty staging directories are removed here. Any unexpected
        // name or non-empty directory leaves the complete recovery location intact.
        let known = Set(["items", "candidates", "journal.json", "manifest.json"])
        let names = try TrashFS.names(run)
        guard names.allSatisfy({ known.contains($0) || isJournalTemporary($0) }) else {
            throw TrashSafetyError.recoveryRequired("unexpected recovery files; preserved")
        }
        for name in ["candidates", "items"] {
            if try TrashFS.optionalIdentity(name, in: run) != nil {
                let child = try openPrivate(name, in: run, device: journal.root.device)
                guard try TrashFS.names(child).isEmpty else { throw TrashSafetyError.recoveryRequired("remaining captured items") }
                try TrashFS.remove(name, in: run, directory: true)
            }
        }
        try removeJournalTemporaries(run)
        try transition(.beforeJournalRemoval)
        try TrashFS.remove("journal.json", in: run, directory: false)
        try transition(.afterJournalRemoval)
        try TrashFS.remove("manifest.json", in: run, directory: false)
        try TrashFS.remove(journal.name, in: recovery, directory: true)
    }

    private func isJournalTemporary(_ name: String) -> Bool {
        name.hasPrefix(".journal-") && UUID(uuidString: String(name.dropFirst(9))) != nil
    }
    private func removeJournalTemporaries(_ run: TrashDirectory) throws {
        for name in try TrashFS.names(run) where isJournalTemporary(name) {
            // App-owned metadata only, regular/private/single-link/bounded, never a payload.
            try TrashFS.removeJournalTemporary(name, in: run)
        }
    }
    private func isMetadataOnlyRun(_ run: TrashDirectory) throws -> Bool {
        // Covers initial journal creation failing before any staging directory exists, and
        // the final journal-unlink -> run-rmdir crash window. Never infer payload completion
        // if any other name is present, including an empty "items" directory.
        try TrashFS.names(run).allSatisfy { $0 == "manifest.json" || isJournalTemporary($0) }
    }
    private func reconcileMetadataOnlyRun(_ name: String, run: TrashDirectory, recovery: TrashDirectory) throws -> Bool {
        guard try isMetadataOnlyRun(run) else { return false }
        if try TrashFS.optionalIdentity("manifest.json", in: run) != nil {
            // This has no staged payload, but malformed/unreadable metadata still fails closed.
            let manifest = try TrashFS.read(Manifest.self, name: "manifest.json", in: run)
            guard manifest.version == 1, manifest.name == name else {
                throw TrashSafetyError.recoveryRequired("malformed orphan manifest")
            }
            try TrashFS.remove("manifest.json", in: run, directory: false)
        }
        try removeJournalTemporaries(run)
        try TrashFS.remove(name, in: recovery, directory: true)
        return true
    }
}
