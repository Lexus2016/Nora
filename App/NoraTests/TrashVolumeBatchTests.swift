import Foundation
import MoleKit
import XCTest
@testable import Nora

@MainActor
final class TrashVolumeBatchTests: XCTestCase {
    /// A path that is not a mounted volume: `statfs` fails, so the part counts as Finder-only.
    private func unmountedDisk() -> TrashLocation {
        .volume(mount: FileManager.default.temporaryDirectory
            .appendingPathComponent("nora-not-a-disk-\(UUID().uuidString)", isDirectory: true), label: "USB")
    }

    private func homeItems(_ identity: String = "home", _ count: Int = 2) -> TrashReminderPart {
        TrashReminderPart(contentIdentity: identity, topLevelItemCount: count, entryCount: count, logicalBytes: 100)
    }

    private func diskItems(_ location: TrashLocation, _ identity: String = "disk", _ count: Int = 4) -> TrashReminderPart {
        TrashReminderPart(location: location, label: location.label, contentIdentity: identity,
                          topLevelItemCount: count, entryCount: count, logicalBytes: 900)
    }

    func testBatchTotalsAndFinderHandOff() {
        let disk = unmountedDisk()
        let batch = TrashReminderSnapshot(parts: [homeItems(), diskItems(disk)])
        XCTAssertEqual(batch.topLevelItemCount, 6)
        XCTAssertEqual(batch.entryCount, 6)
        XCTAssertEqual(batch.logicalBytes, 1000)
        XCTAssertEqual(batch.deletableTopLevelItemCount, 2)
        XCTAssertEqual(batch.finderOnlyLabels, ["USB"])
        XCTAssertEqual(batch.volumeLabels, ["USB"])
        XCTAssertEqual(batch.finderRootURL, disk.rootURL)
    }

    func testAnUnreadableDiskKeepsHomeDeletionAvailable() {
        let batch = TrashReminderSnapshot(parts: [homeItems(), diskItems(unmountedDisk())])
        XCTAssertGreaterThan(batch.deletableTopLevelItemCount, 0)
        XCTAssertEqual(batch.finderOnlyLabels, ["USB"])
        let model = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
        model.setSnapshotFixture(phase: .review, snapshot: batch)
        // A fixture model is terminally stopped, so it may never act; the batch itself is what
        // decides whether Nora can delete and what it must hand to Finder.
        XCTAssertEqual(model.finderOnlyLabels, ["USB"])
    }

    func testOnlyFinderItemsOfferFinderInsteadOfDeletion() {
        let disk = unmountedDisk()
        let batch = TrashReminderSnapshot(parts: [diskItems(disk)])
        XCTAssertEqual(batch.deletableTopLevelItemCount, 0)
        XCTAssertEqual(batch.finderOnlyLabels, ["USB"])
        XCTAssertEqual(batch.finderRootURL, disk.rootURL)
    }

    func testArrivalsAreComparedPerRootAndANewDiskCounts() {
        let disk = unmountedDisk()
        let first = TrashReminderSnapshot(parts: [homeItems("home-1")])
        XCTAssertFalse(first.hasArrivals(since: first))
        XCTAssertTrue(TrashReminderSnapshot(parts: [homeItems("home-2")]).hasArrivals(since: first))
        XCTAssertTrue(TrashReminderSnapshot(parts: [homeItems("home-1"), diskItems(disk)]).hasArrivals(since: first))
        let both = TrashReminderSnapshot(parts: [homeItems("home-1"), diskItems(disk, "disk-1")])
        let unchanged = TrashReminderSnapshot(parts: [homeItems("home-1"), diskItems(disk, "disk-1")])
        XCTAssertFalse(unchanged.hasArrivals(since: both))
        XCTAssertTrue(unchanged.matchesContents(of: both))
        XCTAssertTrue(TrashReminderSnapshot(parts: [homeItems("home-1"), diskItems(disk, "disk-2")])
            .hasArrivals(since: both))
    }

    /// Deleting the Mac's items must not close the panel as if the disk's Trash were handled.
    func testPartialDeletionKeepsFinderOnlyItemsOnScreen() async {
        let disk = unmountedDisk()
        let batch = TrashReminderSnapshot(parts: [homeItems(), diskItems(disk)])
        var services = TrashReminderServices.disabled
        services.scan = { _ in batch }
        services.execute = { snapshot, _ in
            .init(status: .completed, deletedEntryCount: snapshot.deletableTopLevelItemCount,
                  detail: "Synthetic result. No filesystem action.")
        }
        let model = TrashReminderModel(services: services, monitor: InertTrashDirectoryMonitor(),
                                       permitsMonitoring: false)
        model.openReview()
        await waitUntil { model.phase == .review }
        XCTAssertTrue(model.canEmptyTrash)
        model.emptyTrash()
        await waitUntil { model.isPresented && model.phase == .review && model.snapshot?.parts.count == 1 }
        XCTAssertEqual(model.snapshot?.parts.first?.label, "USB")
        XCTAssertEqual(model.snapshot?.deletableTopLevelItemCount, 0)
        XCTAssertEqual(model.notice, String(localized: "The Trash on a connected disk must be emptied in Finder."))
        XCTAssertFalse(model.operationInProgress)
    }

    /// The live backend used to turn a disk it could not empty into `.failed`, which made the panel say
    /// "could not finish" after the Mac's own Trash had been emptied completely.
    func testADiskNoraCannotEmptyNeverMakesTheCleanupFail() {
        let skipped = TrashReminderServices.fold(.completed, eligible: false, result: nil)
        XCTAssertEqual(skipped, .completed, "a part that was never eligible changes nothing")

        var status = TrashReminderServices.fold(.completed, eligible: true, result: .completed)
        status = TrashReminderServices.fold(status, eligible: false, result: nil)
        XCTAssertEqual(status, .completed, "home emptied, then a FAT disk handed to Finder: a complete cleanup")

        let failed = TrashReminderServices.fold(status, eligible: true, result: .failed)
        XCTAssertEqual(failed, .failed, "a real failure on an eligible part still counts")
        XCTAssertEqual(TrashReminderServices.fold(failed, eligible: false, result: nil), .failed,
                       "and a skipped part does not hide it")
        XCTAssertEqual(TrashReminderServices.fold(.completed, eligible: true, result: .recoveryRequired), .recoveryRequired)
        XCTAssertEqual(TrashReminderServices.fold(.completed, eligible: true, result: .requiresNewReview), .requiresNewReview)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The model did not reach the expected state")
    }
}
