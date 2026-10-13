import XCTest
@testable import Nora

final class SecurityScopeTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nora-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeFolders(_ paths: [String]) throws {
        for path in paths {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    func testScheduleIsDueWithoutHistoryAndAfterItsInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ScanSchedule.isDue(now: now, last: nil, cadence: .daily))
        XCTAssertFalse(ScanSchedule.isDue(now: now, last: now.addingTimeInterval(-3_600), cadence: .daily))
        XCTAssertTrue(ScanSchedule.isDue(now: now, last: now.addingTimeInterval(-90_000), cadence: .daily))
        XCTAssertFalse(ScanSchedule.isDue(now: now, last: now.addingTimeInterval(-3 * 86_400), cadence: .weekly))
        XCTAssertTrue(ScanSchedule.isDue(now: now, last: now.addingTimeInterval(-8 * 86_400), cadence: .weekly))
    }

    func testDatabaseUpdateIsDueAtMostOnceADay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ScanSchedule.isUpdateDue(now: now, last: nil))
        XCTAssertFalse(ScanSchedule.isUpdateDue(now: now, last: now.addingTimeInterval(-86_000)))
        XCTAssertTrue(ScanSchedule.isUpdateDue(now: now, last: now.addingTimeInterval(-86_400)))
    }

    func testFullScopeSkipsICloudFoldersAndSplitsLibrary() throws {
        try makeFolders(["Documents", "Library/Caches", "Library/CloudStorage", "Library/Mobile Documents"])
        let plan = ScanPlanner.fullPlan(home: home)
        XCTAssertEqual(plan.skippedICloud, 2)
        XCTAssertTrue(plan.roots.contains(home.appendingPathComponent("Documents").path))
        XCTAssertTrue(plan.roots.contains(home.appendingPathComponent("Library/Caches").path))
        XCTAssertFalse(plan.roots.contains { $0.hasSuffix("/CloudStorage") || $0.hasSuffix("/Mobile Documents") })
    }

    func testQuickScopeDedupesAndNeverScansSystemPaths() throws {
        try makeFolders(["Downloads", "Desktop"])
        let program = home.appendingPathComponent("Downloads/agent").path
        FileManager.default.createFile(atPath: program, contents: Data("fixture".utf8))
        let plan = ScanPlanner.plan(.quick, home: home,
                                    launchPaths: [program, program, "/System/Library/CoreServices"])
        XCTAssertEqual(plan.roots.filter { $0 == program }.count, 1)
        XCTAssertFalse(plan.roots.contains("/System/Library/CoreServices"))
        XCTAssertTrue(plan.roots.contains(home.appendingPathComponent("Desktop").path))
        XCTAssertEqual(plan.skippedICloud, 0)
    }
}
