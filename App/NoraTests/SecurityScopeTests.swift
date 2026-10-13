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

final class BrewEnvironmentTests: XCTestCase {
    /// brew exits with "$HOME must be set to run brew" when the environment lacks HOME.
    func testBrewEnvironmentKeepsHome() {
        XCTAssertNotNil(BrewTools.environment["HOME"])
        XCTAssertEqual(BrewTools.environment["PATH"], "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertTrue(BrewTools.directories.contains("/opt/homebrew/sbin"), "clamd lives in sbin")
        XCTAssertEqual(BrewTools.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
    }

    /// The Downloads watch needs clamd, which Homebrew links into sbin. Runs only where ClamAV is installed.
    func testClamdIsFoundInSbin() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/sbin/clamd"), "ClamAV is not installed")
        XCTAssertEqual(ClamAVTools.locate().clamd?.path, "/opt/homebrew/sbin/clamd")
    }
}

final class OrphanAndCopyTests: XCTestCase {
    /// Only scanners whose parent is launchd and whose arguments name Nora's ClamAV folder.
    func testOrphanedScannersAreOnlyNorasOwn() {
        let root = "/Users/u/Library/Application Support/Nora/clamav"
        let ps = [
            "  101     1 /opt/homebrew/bin/clamscan -r --infected --no-summary -d \(root)/database /Applications",
            "  102   500 /opt/homebrew/bin/clamscan -r -d \(root)/database /Users/u",
            "  103     1 /opt/homebrew/bin/clamscan -r /Users/u/Downloads",
            "  104     1 /opt/homebrew/sbin/clamd --foreground --config-file \(root)/clamd.conf",
            "  105     1 /usr/bin/vim \(root)/clamd.conf",
            "  106     1 /opt/homebrew/bin/clamscan -r -d \(root)-backup/database /Users/u",
            "  107     1 /opt/homebrew/bin/clamscan -r /Users/u/notes-about \(root)/database",
        ].joined(separator: "\n")
        XCTAssertEqual(ClamAVOrphans.orphans(in: ps, root: root), [101, 104])
    }

    @MainActor func testCopiedCommandDropsAskpassOnlyWhereSudoStarts() {
        XCTAssertEqual(CommandPreview.terminalForm("sudo -A -v && mo clean"), "sudo -v && mo clean")
        XCTAssertEqual(CommandPreview.terminalForm("mo clean; sudo -A -v && mo optimize"), "mo clean; sudo -v && mo optimize")
        XCTAssertEqual(CommandPreview.terminalForm("mo uninstall 'Example sudo -A App'"), "mo uninstall 'Example sudo -A App'")
        XCTAssertEqual(CommandPreview.terminalForm("mo uninstall 'Example; sudo -A App'"), "mo uninstall 'Example; sudo -A App'")
        XCTAssertEqual(CommandPreview.terminalForm("sudo -A -v && mo uninstall 'A && sudo -A B'"), "sudo -v && mo uninstall 'A && sudo -A B'")
    }
}
