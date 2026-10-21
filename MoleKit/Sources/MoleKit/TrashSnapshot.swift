import Foundation

public enum TrashEntryType: String, Codable, Sendable { case file, directory, symbolicLink }

/// Metadata identity, not a content hash. In-place writes through an already-open descriptor
/// and a malicious process running as the same user are outside the atomicity guarantee.
public struct TrashFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let ownerID: UInt32
    public let mode: UInt32
    public let type: TrashEntryType
    public let size: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64

    func sameObject(as other: Self) -> Bool {
        device == other.device && inode == other.inode && ownerID == other.ownerID &&
        mode == other.mode && type == other.type && birthSeconds == other.birthSeconds &&
        birthNanoseconds == other.birthNanoseconds
    }

    /// A successful rename can change ctime. All other recorded fields must still match.
    func matchesAfterRename(_ other: Self) -> Bool {
        sameObject(as: other) && size == other.size && modifiedSeconds == other.modifiedSeconds &&
        modifiedNanoseconds == other.modifiedNanoseconds
    }
}

public struct TrashSnapshotEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let identity: TrashFileIdentity
    public var type: TrashEntryType { identity.type }
    public var size: UInt64 { identity.size }
}

/// A complete, immutable review of the current user's home .Trash only. A scan never returns
/// partial data. Symlinks are leaves. Hidden names are included; other volumes are rejected.
public struct TrashSnapshot: Codable, Sendable, Identifiable {
    public let id: UUID
    public let scannedAt: Date
    public let rootIdentity: TrashFileIdentity
    public let entries: [TrashSnapshotEntry]
    public var entryCount: Int { entries.count }
    public var topLevelItemCount: Int { entries.filter { !$0.relativePath.contains("/") }.count }
    /// Logical bytes, including hard-link duplication. This is NOT bytes that will be reclaimed.
    public let estimatedLogicalBytes: UInt64

    public func matchesContents(of other: Self) -> Bool {
        rootIdentity == other.rootIdentity && entries == other.entries
    }

    /// Finder rewrites its view settings here whenever the Trash window is looked at. The user did
    /// not throw it away, so it never counts as something new. It stays in the manifest like any entry.
    static let systemMetadataNames: Set<String> = [".DS_Store"]

    private var topLevelEntries: [TrashSnapshotEntry] { entries.filter { !$0.relativePath.contains("/") } }

    /// The Trash holds something the user put there, not only Finder's own files.
    public var hasUserItems: Bool {
        topLevelEntries.contains { !Self.systemMetadataNames.contains($0.relativePath) }
    }

    /// A top-level item is here that `other` did not have, or one replaced an object of the same name.
    /// Items that only left do not count: put back or emptied by hand, they need no new question.
    public func hasArrivals(since other: Self) -> Bool {
        let before = Dictionary(other.topLevelEntries.map { ($0.relativePath, $0.identity) }, uniquingKeysWith: { first, _ in first })
        return topLevelEntries.contains { entry in
            guard !Self.systemMetadataNames.contains(entry.relativePath) else { return false }
            guard let known = before[entry.relativePath] else { return true }
            return !known.sameObject(as: entry.identity)
        }
    }
}

public final class TrashCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

public enum TrashExecutionStatus: String, Sendable {
    case completed, cancelled, requiresNewReview, recoveryRequired, failed
}

public struct TrashExecutionResult: Sendable {
    public let status: TrashExecutionStatus
    public let deletedEntryCount: Int
    public let message: String
    public let recoveryDirectoryURL: URL?
}

public struct TrashRecoveryStatus: Sendable {
    public let blocksNewRun: Bool
    public let message: String
    public let recoveryDirectoryURL: URL?
}

public enum TrashSafetyError: Error, LocalizedError {
    case unavailable(String)
    case incomplete(String)
    case changed(String)
    case recoveryRequired(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Home Trash is unavailable: \(reason)"
        case .incomplete(let reason): "Trash could not be completely reviewed: \(reason)"
        case .changed(let reason): "Trash changed. Review it again before deleting: \(reason)"
        case .recoveryRequired(let reason): "Trash recovery is required: \(reason)"
        case .io(let reason): "Trash operation stopped safely: \(reason)"
        }
    }
}

struct TrashScanLimits {
    var maximumEntries = 50_000
    var maximumDepth = 128
    var maximumPathBytes = 16 * 1024 * 1024
    var timeout: TimeInterval = 30
}

/// Injection seams are internal: production never accepts arbitrary cleanup paths or hooks.
enum TrashTransition: Equatable {
    case scanning(String)
    case beforeStage(Int), afterStage(Int)
    case beforeCapture(Int), afterCapture(Int)
    case beforeDelete(Int), afterDelete(Int)
    case afterUnlink(Int), beforeRemovalSync(Int)
    case beforeJournal(String), afterJournal(String)
    case beforeRestore(String), afterRestore(String)
    case beforeJournalRemoval, afterJournalRemoval
}

enum TrashInjectedFailure: Error { case simulatedCrash }
