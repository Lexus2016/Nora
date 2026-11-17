import Foundation
import MoleKit

/// One reviewed Trash root: the home Trash or a mounted disk's per-user Trash.
/// Один переглянутий Кошик: домашній або Кошик підключеного диска.
struct TrashReminderPart: Sendable {
    /// nil for a synthetic fixture part, which never reaches the filesystem.
    let location: TrashLocation?
    let label: String
    let contentIdentity: String
    let topLevelItemCount: Int
    let entryCount: Int
    let logicalBytes: Int64
    let manifest: TrashSnapshot?

    init(location: TrashLocation, snapshot: TrashSnapshot) {
        self.location = location
        label = location.label
        contentIdentity = snapshot.id.uuidString
        topLevelItemCount = snapshot.topLevelItemCount
        entryCount = snapshot.entryCount
        logicalBytes = Int64(clamping: snapshot.estimatedLogicalBytes)
        manifest = snapshot
    }

    init(contentIdentity: String, topLevelItemCount: Int, entryCount: Int, logicalBytes: Int64,
         manifest: TrashSnapshot? = nil, label: String = "Home") {
        location = nil
        self.label = label
        self.contentIdentity = contentIdentity
        self.topLevelItemCount = topLevelItemCount
        self.entryCount = entryCount
        self.logicalBytes = logicalBytes
        self.manifest = manifest
    }

    /// Synthetic parts that name a real location, for tests of the multi-disk batch.
    init(location: TrashLocation?, label: String, contentIdentity: String, topLevelItemCount: Int,
         entryCount: Int, logicalBytes: Int64, manifest: TrashSnapshot? = nil) {
        self.location = location
        self.label = label
        self.contentIdentity = contentIdentity
        self.topLevelItemCount = topLevelItemCount
        self.entryCount = entryCount
        self.logicalBytes = logicalBytes
        self.manifest = manifest
    }

    var key: String { location?.rootURL.path ?? "fixture" }
    var isDeletable: Bool { location?.supportsPermanentDeletion ?? true }
    var hasUserItems: Bool { manifest?.hasUserItems ?? (topLevelItemCount > 0) }

    func matchesContents(of other: Self) -> Bool {
        guard key == other.key else { return false }
        if let manifest, let otherManifest = other.manifest { return manifest.matchesContents(of: otherManifest) }
        return manifest == nil && other.manifest == nil && contentIdentity == other.contentIdentity
    }

    func hasArrivals(since other: Self?) -> Bool {
        guard let other else { return hasUserItems }
        if let manifest, let otherManifest = other.manifest { return manifest.hasArrivals(since: otherManifest) }
        return !matchesContents(of: other)
    }
}

/// The reviewed batch: every Trash root that had items when the snapshot was taken.
/// Переглянутий набір: усі Кошики, у яких на момент знімка були елементи.
struct TrashReminderSnapshot: Sendable {
    let parts: [TrashReminderPart]

    init(parts: [TrashReminderPart]) {
        self.parts = parts
    }

    /// A synthetic fixture with one part and no filesystem manifest.
    init(contentIdentity: String, topLevelItemCount: Int, entryCount: Int, logicalBytes: Int64,
         manifest: TrashSnapshot? = nil) {
        parts = [TrashReminderPart(contentIdentity: contentIdentity, topLevelItemCount: topLevelItemCount,
                                   entryCount: entryCount, logicalBytes: logicalBytes, manifest: manifest)]
    }

    var topLevelItemCount: Int { parts.reduce(0) { $0 + $1.topLevelItemCount } }
    var entryCount: Int { parts.reduce(0) { $0 + $1.entryCount } }
    var logicalBytes: Int64 { parts.reduce(0) { $0 + $1.logicalBytes } }
    /// The batch's identity across every reviewed root. A single-part batch (every fixture) keeps
    /// the exact string the backend returned; multiple roots are joined with their root key.
    var contentIdentity: String {
        if parts.count == 1 { return parts[0].contentIdentity }
        return parts.map { "\($0.key)#\($0.contentIdentity)" }.joined(separator: "|")
    }

    var deletableTopLevelItemCount: Int {
        parts.filter(\.isDeletable).reduce(0) { $0 + $1.topLevelItemCount }
    }
    /// Names of connected disks whose Trash Nora can review but cannot empty itself.
    var finderOnlyLabels: [String] {
        parts.filter { !$0.isDeletable && $0.topLevelItemCount > 0 }.map(\.label)
    }
    /// Names of connected disks that currently hold reviewed items.
    var volumeLabels: [String] {
        parts.filter { $0.location?.kind == .volume && $0.topLevelItemCount > 0 }.map(\.label)
    }
    /// The first disk whose Trash Nora cannot empty itself, for the Finder hand-off.
    var finderRootURL: URL? {
        parts.first { !$0.isDeletable && $0.topLevelItemCount > 0 }?.location?.rootURL
    }

    func matchesContents(of other: Self) -> Bool {
        guard parts.count == other.parts.count else { return false }
        return zip(parts, other.parts).allSatisfy { $0.matchesContents(of: $1) }
    }

    /// There is something here the user has not been asked about. Against nothing, any item of
    /// theirs; against an earlier batch, an item that was not in it (per Trash root).
    func hasArrivals(since other: Self?) -> Bool {
        guard let other else { return parts.contains(where: \.hasUserItems) }
        return parts.contains { part in
            part.hasArrivals(since: other.parts.first { $0.key == part.key })
        }
    }
}

enum TrashReminderBlock {
    case busy(String)
    case recovery(String)
}

struct TrashReminderOutcome: Sendable {
    enum Status: Equatable, Sendable { case completed, cancelled, requiresNewReview, recoveryRequired, failed }
    let status: Status
    let deletedEntryCount: Int
    let detail: String
}

struct TrashReminderRecovery: Sendable {
    let blocksNewRun: Bool
    let detail: String
}

/// Injected at the app boundary. Rendering and tests never instantiate a live filesystem service.
@MainActor
struct TrashReminderServices {
    var scan: (TrashCancellationToken) async throws -> TrashReminderSnapshot
    var execute: (TrashReminderSnapshot, TrashCancellationToken) async -> TrashReminderOutcome
    var recoveryStatus: () async -> TrashReminderRecovery
    var recover: () async -> TrashReminderRecovery

    /// Test hosts and visual snapshots cannot reach the real user Trash, even through a manual action.
    static var disabled: Self {
        Self(scan: { _ in throw DisabledError() },
             execute: { _, _ in TrashReminderOutcome(status: .failed, deletedEntryCount: 0, detail: "Trash services are disabled in this fixture.") },
             recoveryStatus: { TrashReminderRecovery(blocksNewRun: false, detail: "") },
             recover: { TrashReminderRecovery(blocksNewRun: false, detail: "") })
    }

    private struct DisabledError: LocalizedError {
        var errorDescription: String? { "Trash services are disabled in this fixture." }
    }

    static func live() -> Self {
        Self(scan: { cancellation in
            return try await Task.detached(priority: .utility) {
                let locations = [TrashLocation.home()] + TrashLocations.mounted()
                var parts: [TrashReminderPart] = []
                for location in locations {
                    do {
                        let snapshot = try TrashService(location: location).scan(cancellation: cancellation)
                        if snapshot.topLevelItemCount > 0 { parts.append(TrashReminderPart(location: location, snapshot: snapshot)) }
                    } catch {
                        // A disk can be unplugged while the scan walks it, or its Trash can be
                        // unreadable. The home Trash must still be reviewed; the disk disappears
                        // from this batch until it is readable again.
                        if location.kind == .home { throw error }
                    }
                }
                return TrashReminderSnapshot(parts: parts)
            }.value
        }, execute: { snapshot, cancellation in
            let parts = snapshot.parts.filter { ($0.manifest?.topLevelItemCount ?? 0) > 0 }
            return await Task.detached(priority: .utility) {
                var deleted = 0
                var status: TrashReminderOutcome.Status = .completed
                var details: [String] = []
                for part in parts {
                    guard let manifest = part.manifest, let location = part.location else { continue }
                    guard location.supportsPermanentDeletion else {
                        details.append(String(localized: "The Trash on \(part.label) must be emptied in Finder."))
                        if status == .completed { status = .failed }
                        continue
                    }
                    let result = TrashService(location: location).execute(manifest, cancellation: cancellation)
                    deleted += result.deletedEntryCount
                    details.append(result.message)
                    status = Self.merge(status, result: result.status)
                    if status == .requiresNewReview || status == .recoveryRequired { break }
                }
                return TrashReminderOutcome(status: status, deletedEntryCount: deleted,
                                            detail: details.joined(separator: " "))
            }.value
        }, recoveryStatus: {
            return await Task.detached(priority: .utility) {
                let locations = [TrashLocation.home()] + TrashLocations.mounted()
                for location in locations {
                    let result = TrashService(location: location).recoveryStatus()
                    if result.blocksNewRun {
                        return TrashReminderRecovery(blocksNewRun: true,
                                                     detail: "\(location.label): \(result.message)")
                    }
                }
                return TrashReminderRecovery(blocksNewRun: false, detail: "")
            }.value
        }, recover: {
            return await Task.detached(priority: .utility) {
                let locations = [TrashLocation.home()] + TrashLocations.mounted()
                var detail = ""
                for location in locations {
                    let result = TrashService(location: location).recover()
                    if result.blocksNewRun {
                        return TrashReminderRecovery(blocksNewRun: true, detail: "\(location.label): \(result.message)")
                    }
                    if !detail.isEmpty { detail += " " }
                    detail += result.message
                }
                return TrashReminderRecovery(blocksNewRun: false, detail: detail)
            }.value
        })
    }

    nonisolated private static func merge(_ status: TrashReminderOutcome.Status,
                                            result: TrashExecutionStatus) -> TrashReminderOutcome.Status {
        switch result {
        case .recoveryRequired: return .recoveryRequired
        case .requiresNewReview: return status == .recoveryRequired ? status : .requiresNewReview
        case .failed: return status == .completed ? .failed : status
        case .cancelled: return status == .completed ? .cancelled : status
        case .completed: return status
        }
    }
}
