import XCTest
@testable import MoleKit

/// The closing block of a Mole run feeds Nora's result cards. The `=====` rulers around it are
/// terminal decoration: they must never reach a card, and they must not use up one of its lines.
final class MoleSummaryTests: XCTestCase {
    func testBlockBetweenTheLastTwoRulersIsReturnedWithoutRulers() {
        let output = "noise\n=====\nCleanup complete\nTracked cleanup: 2MB | Items cleaned: 1\n=====\n"
        XCTAssertEqual(MoleSummary.lines(output), ["Cleanup complete", "Tracked cleanup: 2MB | Items cleaned: 1"])
    }

    func testLoneRulerDoesNotUseUpOneOfTheFourLines() {
        let output = "one\ntwo\nthree\nfour\nfive\n==============\n"
        XCTAssertEqual(MoleSummary.lines(output), ["two", "three", "four", "five"])
    }

    func testOutputWithoutRulersKeepsTheLastFourLines() {
        XCTAssertEqual(MoleSummary.lines("a\n\nb\nc\nd\ne\n"), ["b", "c", "d", "e"])
    }
}
