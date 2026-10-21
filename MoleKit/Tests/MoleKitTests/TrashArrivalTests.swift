import Foundation
import XCTest
@testable import MoleKit

/// The reminder asks again only about items it has not asked about. These use real snapshot entries:
/// a manifest-less fixture treats every change as an arrival and would prove nothing.
final class TrashArrivalTests: XCTestCase {
    private func identity(inode: UInt64, born: Int64 = 1_000, type: TrashEntryType = .file, size: UInt64 = 10) -> TrashFileIdentity {
        TrashFileIdentity(device: 1, inode: inode, ownerID: 501, mode: 0o100644, type: type, size: size,
                          modifiedSeconds: 2_000, modifiedNanoseconds: 0, changedSeconds: 2_000, changedNanoseconds: 0,
                          birthSeconds: born, birthNanoseconds: 0)
    }

    private func entry(_ path: String, inode: UInt64, born: Int64 = 1_000) -> TrashSnapshotEntry {
        TrashSnapshotEntry(relativePath: path, identity: identity(inode: inode, born: born))
    }

    private func snapshot(_ entries: [TrashSnapshotEntry]) -> TrashSnapshot {
        TrashSnapshot(id: UUID(), scannedAt: Date(timeIntervalSince1970: 1_800_000_000),
                      rootIdentity: identity(inode: 1, type: .directory), entries: entries, estimatedLogicalBytes: 0)
    }

    func testNewTopLevelItemIsAnArrival() {
        let reviewed = snapshot([entry("a.txt", inode: 10)])
        let now = snapshot([entry("a.txt", inode: 10), entry("b.txt", inode: 11)])
        XCTAssertTrue(now.hasArrivals(since: reviewed))
    }

    func testSameItemsAreNotAnArrival() {
        let reviewed = snapshot([entry("a.txt", inode: 10), entry("b.txt", inode: 11)])
        XCTAssertFalse(reviewed.hasArrivals(since: reviewed))
    }

    func testItemsThatOnlyLeftAreNotAnArrival() {
        let reviewed = snapshot([entry("a.txt", inode: 10), entry("b.txt", inode: 11)])
        let now = snapshot([entry("a.txt", inode: 10)])
        XCTAssertFalse(now.hasArrivals(since: reviewed), "Put back or emptied by hand: nothing new to ask about")
        XCTAssertFalse(snapshot([]).hasArrivals(since: reviewed))
    }

    func testDifferentObjectUnderTheSameNameIsAnArrival() {
        let reviewed = snapshot([entry("a.txt", inode: 10, born: 1_000)])
        let replaced = snapshot([entry("a.txt", inode: 77, born: 5_000)])
        XCTAssertTrue(replaced.hasArrivals(since: reviewed), "A file thrown away again under the same name is new")
    }

    func testNestedEntriesDoNotCountAsArrivals() {
        let reviewed = snapshot([entry("dir", inode: 10)])
        let now = snapshot([entry("dir", inode: 10), entry("dir/inner.txt", inode: 12)])
        XCTAssertFalse(now.hasArrivals(since: reviewed), "Only top-level items are what the user threw away")
    }

    func testFinderMetadataIsNeverAnArrivalNorAUserItem() {
        let reviewed = snapshot([entry("a.txt", inode: 10)])
        let now = snapshot([entry("a.txt", inode: 10), entry(".DS_Store", inode: 99)])
        XCTAssertFalse(now.hasArrivals(since: reviewed), "Finder rewriting .DS_Store must not reopen the reminder")
        XCTAssertFalse(snapshot([entry(".DS_Store", inode: 99)]).hasUserItems)
        XCTAssertTrue(now.hasUserItems)
        XCTAssertFalse(snapshot([]).hasUserItems)
        XCTAssertEqual(now.topLevelItemCount, 2, "The manifest itself still lists every entry")
    }
}
