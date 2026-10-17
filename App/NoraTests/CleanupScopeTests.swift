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
        let now = Date()
        model.preview = CleanPreview.validated(stdout: "Dry run complete\nPotential space: 60MB | Items: 3\nDetailed file list: synthetic",
                                               list: list, listModified: now, since: now)
        model.stage = .review
        model.selected = Set(model.preview?.items.map(\.path) ?? [])
        return model
    }

    func testOneCategoryCleanProtectsEveryOtherCategory() {
        let model = scanned()
        XCTAssertTrue(model.scope(to: "Browsers"))
        XCTAssertEqual(Set(model.protectedPaths), ["/Users/u/Library/Caches/ExampleCache", "/Users/u/Library/Logs/Example Logs"])
    }

    /// D02: a section Mole could not measure is still listed, because its items are ticked.
    func testUnmeasuredSectionStaysVisible() {
        let model = CleanupModel()
        model.preview = CleanPreview.parse(cleanList: list + "\n=== Logs ===\n/Users/u/Library/Logs/Slow  # size unknown\n", stdout: "")
        model.selected = Set(model.preview?.items.map(\.path) ?? [])
        XCTAssertEqual(model.rankedSections, ["User essentials", "Browsers", "Logs"])
        XCTAssertEqual(model.sizeText("Logs"), String(localized: "Size unknown"))
        XCTAssertEqual(model.selectedSize, 52_600_000 + 1_000_000 + 6_400_000)
    }

    /// D03: with everything ticked, junk that appeared after the review is still protected.
    func testNewJunkIsProtectedEvenWhenEverythingIsTicked() {
        let model = scanned()
        let previewed = Set(model.preview?.items.map(\.path) ?? [])
        let fresh = Array(previewed) + ["/Users/u/Library/Caches/New"]
        XCTAssertEqual(CleanupModel.protected(reviewed: model.protectedPaths, fresh: fresh, chosen: model.selected, previewed: previewed),
                       ["/Users/u/Library/Caches/New"])
    }

    /// The re-check before a partial clean counts only when Mole finished and, if it found
    /// anything, wrote a list during this check that Nora could read.
    func testFreshCheckMustBeCompleteAndReadable() {
        let now = Date()
        let found = "Dry run complete - no changes made\nPotential space: 1GB | Items: 3\nDetailed file list: ~/.config/mole/clean-list.txt"
        XCTAssertEqual(CleanupModel.freshPaths(stdout: found, list: list, listModified: now, since: now)?.count, 3)
        XCTAssertNil(CleanupModel.freshPaths(stdout: found, list: nil, listModified: now, since: now), "an unreadable list protects nothing")
        XCTAssertNil(CleanupModel.freshPaths(stdout: found, list: list, listModified: now.addingTimeInterval(-600), since: now), "a list from an earlier run")
        XCTAssertNil(CleanupModel.freshPaths(stdout: "Dry run incomplete\nDetailed file list: x", list: list, listModified: now, since: now))
        XCTAssertNil(CleanupModel.freshPaths(stdout: "", list: list, listModified: now, since: now))
        XCTAssertEqual(CleanupModel.freshPaths(stdout: "Dry run complete - no changes made\nNo significant reclaimable space detected, system already clean.",
                                               list: nil, listModified: nil, since: now), [], "nothing found: nothing new to protect")
    }

    func testClearedCategoryIsNeverTickedBack() {
        let model = scanned()
        model.selected.subtract(model.items(in: "Browsers").map(\.path))
        XCTAssertFalse(model.scope(to: "Browsers"), "nothing ticked in the category means nothing to clean")
        XCTAssertTrue(model.protectedPaths.contains("/Users/u/Library/Caches/Browser/GPUCache"))
    }
}
