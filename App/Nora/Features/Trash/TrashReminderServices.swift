import Foundation
import MoleKit

/// The optional backend manifest is opaque to presentation code. Synthetic snapshots have none.
struct TrashReminderSnapshot: Sendable {
    let contentIdentity: String
    let topLevelItemCount: Int
    let entryCount: Int
    let logicalBytes: Int64
    let manifest: TrashSnapshot?

    init(contentIdentity: String, topLevelItemCount: Int, entryCount: Int, logicalBytes: Int64, manifest: TrashSnapshot? = nil) {
        self.contentIdentity = contentIdentity
        self.topLevelItemCount = topLevelItemCount
        self.entryCount = entryCount
        self.logicalBytes = logicalBytes
        self.manifest = manifest
    }

    func matchesContents(of other: Self) -> Bool {
        if let manifest, let otherManifest = other.manifest { return manifest.matchesContents(of: otherManifest) }
        return manifest == nil && other.manifest == nil && contentIdentity == other.contentIdentity
    }

    /// There is something here the user has not been asked about. Against nothing, any item of theirs;
    /// against an earlier batch, an item that was not in it. A snapshot without a manifest (a fixture)
    /// has no items to compare, so any change counts.
    func hasArrivals(since other: Self?) -> Bool {
        guard let other else { return manifest?.hasUserItems ?? (topLevelItemCount > 0) }
        if let manifest, let otherManifest = other.manifest { return manifest.hasArrivals(since: otherManifest) }
        return !matchesContents(of: other)
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
        let service = HomeTrashService()
        return Self(scan: { cancellation in
            try await Task.detached(priority: .utility) {
                let snapshot = try service.scan(cancellation: cancellation)
                return TrashReminderSnapshot(contentIdentity: snapshot.id.uuidString,
                    topLevelItemCount: snapshot.topLevelItemCount, entryCount: snapshot.entryCount,
                    logicalBytes: Int64(clamping: snapshot.estimatedLogicalBytes), manifest: snapshot)
            }.value
        }, execute: { snapshot, cancellation in
            guard let manifest = snapshot.manifest else {
                return TrashReminderOutcome(status: .failed, deletedEntryCount: 0, detail: "Missing reviewed manifest.")
            }
            return await Task.detached(priority: .utility) {
                let result = service.execute(manifest, cancellation: cancellation)
                let status: TrashReminderOutcome.Status
                switch result.status {
                case .completed: status = .completed
                case .cancelled: status = .cancelled
                case .requiresNewReview: status = .requiresNewReview
                case .recoveryRequired: status = .recoveryRequired
                case .failed: status = .failed
                }
                return TrashReminderOutcome(status: status, deletedEntryCount: result.deletedEntryCount, detail: result.message)
            }.value
        }, recoveryStatus: {
            await Task.detached(priority: .utility) {
                let result = service.recoveryStatus()
                return TrashReminderRecovery(blocksNewRun: result.blocksNewRun, detail: result.message)
            }.value
        }, recover: {
            await Task.detached(priority: .utility) {
                let result = service.recover()
                return TrashReminderRecovery(blocksNewRun: result.blocksNewRun, detail: result.message)
            }.value
        })
    }
}
