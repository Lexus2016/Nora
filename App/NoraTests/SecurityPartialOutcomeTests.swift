import XCTest
@testable import Nora

final class SecurityPartialOutcomeTests: XCTestCase {
    func testPartialQuarantineErrorNamesUnloadAndPreservesCause() {
        let error = SecurityError.quarantineAfterUnloadFailed(label: "test.fixture", detail: "fixture move denied")
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("test.fixture"))
        XCTAssertTrue(description.contains("fixture move denied"))
    }
}
