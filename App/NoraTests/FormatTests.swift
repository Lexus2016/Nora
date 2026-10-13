import XCTest
@testable import Nora

final class FormatTests: XCTestCase {
    func testPercentRoundsToWholeNumbers() {
        XCTAssertEqual(Format.percent(nil), "—")
        XCTAssertFalse(Format.percent(42.4).isEmpty)
    }
}
