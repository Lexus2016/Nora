import XCTest
@testable import MoleKit

/// Mole 1.67 reworded the closing lines of `mo clean`: "Potential space: X | Items: N | Categories: M"
/// became "Potential space: X · N items" (a trailing "+" marks a partial total), and "Tracked cleanup:
/// X | Items cleaned: N" became "Removed: X · N items". A preview whose item count is not read is
/// refused, so a parser that only knew "Items: N" made every Cleanup scan on Mole 1.67 or newer fail.
final class Mole169FormatTests: XCTestCase {
    private let list = """
    # Mole Cleanup Preview - 2026-11-05 18:00:00

    === User essentials ===
    /Users/u/Library/Caches/ExampleCache  # 52.6MB

    === Browsers ===
    /Users/u/Library/Caches/Browser/GPUCache  # 6.4MB
    """

    private func validated(footer: String) -> CleanPreview? {
        let stdout = """
        ➤ User essentials
          → User app cache · 22 items, 738.8MB dry
        ======================================================================
        Dry run complete - no changes made
        \(footer)
        Detailed file list: /Users/u/.config/mole/clean-list.txt
        ======================================================================
        """
        let now = Date()
        return CleanPreview.validated(stdout: stdout, list: list, listModified: now, since: now.addingTimeInterval(-60))
    }

    func testPreviewWithTheNewItemCountIsAcceptedAndCounted() {
        let preview = validated(footer: "Potential space: 898.0MB · 179 items")
        XCTAssertNotNil(preview, "Mole 1.69 prints the count as '· 179 items'")
        XCTAssertEqual(preview?.reportedItemCount, 179)
        XCTAssertEqual(preview?.potentialSize, 898_000_000)
    }

    func testPartialTotalKeepsItsItemCount() {
        let preview = validated(footer: "Potential space: 901.5MB+ · 183 items")
        XCTAssertEqual(preview?.reportedItemCount, 183)
        XCTAssertEqual(preview?.potentialSize, 901_500_000)
    }

    func testSingleItemIsSingular() {
        XCTAssertEqual(validated(footer: "Potential space: 4.0MB · 1 item")?.reportedItemCount, 1)
    }

    func testOlderFooterIsStillAccepted() {
        let preview = validated(footer: "Potential space: 2.48GB | Items: 967 | Categories: 6")
        XCTAssertEqual(preview?.reportedItemCount, 967)
    }

    func testInstallerEmptyResultOfMole169IsRecognised() {
        XCTAssertTrue(InstallerDriver.isEmptyScan(status: .exited(0), output: "✓ No installer files to clean"))
    }
}
