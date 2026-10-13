import XCTest
@testable import Nora

/// The unused rule: an app is unused when it was last opened 90 days or more ago.
final class AppsUnusedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    func testAppsOpenedWithin90DaysAreUsed() {
        XCTAssertFalse(AppUsage.isUnused(lastUsed: daysAgo(0), now: now))
        XCTAssertFalse(AppUsage.isUnused(lastUsed: daysAgo(89), now: now))
        XCTAssertFalse(AppUsage.isUnused(lastUsed: daysAgo(89.9), now: now))
    }

    func testAppsNotOpenedFor90DaysOrMoreAreUnused() {
        XCTAssertTrue(AppUsage.isUnused(lastUsed: daysAgo(90), now: now))
        XCTAssertTrue(AppUsage.isUnused(lastUsed: daysAgo(400), now: now))
    }

    func testUnknownDateIsNotUnused() {
        XCTAssertFalse(AppUsage.isUnused(lastUsed: nil, now: now))
    }

    func testFutureDateIsNotUnused() {
        XCTAssertFalse(AppUsage.isUnused(lastUsed: now.addingTimeInterval(3_600), now: now))
    }
}
