import XCTest
@testable import Nora

/// Mole's end-of-run summary (1.59 wording) is shown in Nora's language; Nora's own lines and
/// anything unknown pass through.
final class MoleSummaryTextTests: XCTestCase {
    func testOptimizeSummaryFromTheScreenshot() {
        for line in ["Optimization Complete", "Applied 2 optimizations", "15 unchanged | 2 skipped | 1 unavailable", "Optimization pass complete"] {
            let text = MoleSummaryText.localize(line)
            XCTAssertNotEqual(text, line, line)
            XCTAssertFalse(text.contains("optimizations") || text.contains("unchanged"), text)
        }
        XCTAssertTrue(MoleSummaryText.localize("15 unchanged | 2 skipped | 1 unavailable").contains("15"))
    }

    func testCleanPurgeAndInstallerLinesKeepTheirNumbers() {
        XCTAssertTrue(MoleSummaryText.localize("Tracked cleanup: 2.48GB | Items cleaned: 967").contains("967"))
        XCTAssertTrue(MoleSummaryText.localize("Estimated space freed: 3.27GB | Items: 315 | Free: 508.57GB").contains("315"))
        XCTAssertTrue(MoleSummaryText.localize("Removed 2 installers, freed 96.5MB").contains("2"))
        XCTAssertNotEqual(MoleSummaryText.localize("Free space: 512.3GB (+2.1GB)"), "Free space: 512.3GB (+2.1GB)")
    }

    func testNorasOwnAndUnknownLinesPassThrough() {
        XCTAssertEqual(MoleSummaryText.localize("✓ Example App"), "✓ Example App")
        XCTAssertEqual(MoleSummaryText.localize("Something a later Mole prints"), "Something a later Mole prints")
    }
}
