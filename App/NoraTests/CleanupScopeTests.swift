import XCTest
import MoleKit
@testable import Nora

/// F02: a one-category review cleans that category only, and a cleared category stays cleared.
/// The checks run on the plan Nora hands to Mole (the protected paths), not on checkbox state.
@MainActor
final class CleanupScopeTests: XCTestCase {
    private let list = """
    === User essentials ===
    /Users/u/Library/Caches/ExampleCache  # 52.6MB
    /Users/u/Library/Logs/Example Logs  # 1MB

    === Browsers ===
    /Users/u/Library/Caches/Browser/GPUCache  # 6.4MB
    """

    private func scanned() -> CleanupModel {
        let model = CleanupModel()
        model.preview = CleanPreview.parse(cleanList: list, stdout: "")
        model.selected = Set(model.preview?.items.map(\.path) ?? [])
        return model
    }

    func testOneCategoryCleanProtectsEveryOtherCategory() {
        let model = scanned()
        XCTAssertTrue(model.scope(to: "Browsers"))
        XCTAssertEqual(Set(model.protectedPaths), ["/Users/u/Library/Caches/ExampleCache", "/Users/u/Library/Logs/Example Logs"])
    }

    func testClearedCategoryIsNeverTickedBack() {
        let model = scanned()
        model.selected.subtract(model.items(in: "Browsers").map(\.path))
        XCTAssertFalse(model.scope(to: "Browsers"), "nothing ticked in the category means nothing to clean")
        XCTAssertTrue(model.protectedPaths.contains("/Users/u/Library/Caches/Browser/GPUCache"))
    }
}
