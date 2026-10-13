import XCTest
@testable import Nora

/// Every task in Mole 1.59's optimize catalog has Nora's own name and description; the usual
/// attention and skip reasons are rewritten, anything else stays as Mole wrote it.
final class OptimizeTextTests: XCTestCase {
    private let moleTitles = [
        "DNS & Spotlight Check", "Finder Cache Refresh", "App State Cleanup", "Broken Config Repair",
        "Network Cache Refresh", "Database Optimization", "Prevent Finder .DS_Store", "Legacy Overrides",
        "Network Stack Refresh", "Permission Repair", "Spotlight Optimization", "Spotlight Orphan Rules",
        "Periodic Maintenance", "Shared File Lists", "Disk Health", "Login Items",
        "Quarantine Database Cleanup", "Launch Agents Cleanup", "Notifications", "Usage Data",
    ]

    func testWholeCatalogIsCovered() {
        for title in moleTitles {
            XCTAssertNotNil(OptimizeText.description(title), title)
        }
        XCTAssertEqual(OptimizeText.title("Something Mole adds later"), "Something Mole adds later")
    }

    func testUsualReasonsAreRewritten() {
        let quit = OptimizeText.reason("◎ Close these apps before database optimization: Mail Safari")
        XCTAssertTrue(quit.hasSuffix("Mail Safari") && !quit.contains("before database optimization"))
        XCTAssertFalse(OptimizeText.reason("Spotlight index rebuild · skipped (admin access required)").contains("skipped"))
        XCTAssertTrue(OptimizeText.reason("→ Login items all healthy (11 checked)").contains("11"))
        XCTAssertEqual(OptimizeText.reason("→ A line from a later Mole"), "A line from a later Mole")
    }
}
