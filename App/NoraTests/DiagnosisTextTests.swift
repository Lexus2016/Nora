import XCTest
@testable import Nora

/// Mole's performance diagnosis (1.59 wording) is shown in Nora's language; unknown lines stay
/// as Mole wrote them, and the memory holders come out as readable names with sizes.
final class DiagnosisTextTests: XCTestCase {
    private let diagnosis = [
        "◎ Likely bottleneck: WindowServer (~32.5% CPU sustained)",
        "⊙ Desktop composition is busy. When another family is higher, treat this as a likely symptom rather than the root cause.",
        "◎ Memory pressure: swap 12.32GB of 13.96GB used (88%), 80% free",
        "…m.apple.WebKit.WebContent  1.26GB",
        "python3                     1.03GB",
        "claude                      984.8MB",
    ]

    func testKnownLinesAreRewrittenAndHoldersParsed() {
        let text = DiagnosisText.split(diagnosis)
        XCTAssertEqual(text.lines.count, 3)
        XCTAssertFalse(text.lines.contains { $0.contains("Likely bottleneck") || $0.contains("Desktop composition") || $0.contains("Memory pressure") },
                       "every known sentence is Nora's own")
        let share = (32.5).formatted(.number.precision(.fractionLength(0...1)))
        XCTAssertTrue(text.lines[0].contains("WindowServer") && text.lines[0].contains(share), "the share is in the reader's notation")
        XCTAssertTrue(text.lines[2].contains("88") && text.lines[2].contains("80"))
        XCTAssertEqual(text.holders.map(\.name), ["WebKit WebContent", "python3", "claude"])
        XCTAssertEqual(text.holders.count, 3)
    }

    func testUnknownLineStaysAsMoleWroteIt() {
        XCTAssertEqual(DiagnosisText.localize("◎ Something new in a later Mole"), "Something new in a later Mole")
    }

    func testFindingWithASizeIsNotTakenForAProcess() {
        let text = DiagnosisText.split(["◎ Virtual machine holding 4.2GB"])
        XCTAssertTrue(text.holders.isEmpty)
        XCTAssertEqual(text.lines.count, 1)
    }
}
