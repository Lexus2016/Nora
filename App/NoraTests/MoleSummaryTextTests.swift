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

    /// Mole 1.67+ wording: "Removed: X · N items" and "Potential space: X · N items".
    func testMole169CleanLinesAreShownInNorasLanguageWithTheirNumbers() {
        for line in ["Removed: 898.0MB · 179 items", "Potential space: 898.0MB · 179 items"] {
            let text = MoleSummaryText.localize(line)
            XCTAssertNotEqual(text, line, line)
            XCTAssertTrue(text.contains("179"), text)
        }
    }

    /// A trailing "+" on a size means Mole's total is partial: the real figure is at least that much.
    func testPartialTotalsKeepTheirLowerBoundMark() {
        for line in ["Potential space: 898.0MB+ · 179 items", "Removed: 898.0MB+ · 179 items"] {
            let amount = MoleSummaryText.localize(line).components(separatedBy: " · ")[0]
            XCTAssertTrue(amount.hasSuffix("+"), amount)
        }
    }

    func testNothingRemovedLinesAreShownInNorasLanguage() {
        for line in ["System was already clean; no additional space freed.", "No additional space freed.",
                     "No significant reclaimable space detected, system already clean.",
                     "No additional reclaimable space detected."] {
            XCTAssertNotEqual(MoleSummaryText.localize(line), line, line)
        }
    }

    func testNorasOwnAndUnknownLinesPassThrough() {
        XCTAssertEqual(MoleSummaryText.localize("✓ Example App"), "✓ Example App")
        XCTAssertEqual(MoleSummaryText.localize("Something a later Mole prints"), "Something a later Mole prints")
    }
}
