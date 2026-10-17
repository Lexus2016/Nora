import XCTest
import SwiftUI
@testable import Nora

/// Synthetic lookups and view configuration only; no external requests or UI actions.
@MainActor
final class MenuModePolishRegressionTests: XCTestCase {
    func testLatestReleaseFailureSettlesAndCanRetry() async {
        let model = ToolsModel()
        let failed = model.refreshLatest { throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(model.latestBusy)
        await failed?.value
        XCTAssertFalse(model.latestBusy)
        XCTAssertNil(model.latestMole)
        XCTAssertNotNil(model.latestError)
        let retry = model.refreshLatest { "1.99.0" }
        XCTAssertTrue(model.latestBusy)
        XCTAssertNil(model.latestError)
        await retry?.value
        XCTAssertFalse(model.latestBusy)
        XCTAssertEqual(model.latestMole, "1.99.0")
        XCTAssertNil(model.latestError)
    }

    func testLatestReleaseLookupDoesNotOverlap() async {
        let model = ToolsModel()
        let first = model.refreshLatest { "1.99.1" }
        let overlapping = model.refreshLatest { XCTFail("An overlapping lookup must not start"); return "wrong" }
        XCTAssertNil(overlapping)
        await first?.value
        XCTAssertEqual(model.latestMole, "1.99.1")
    }

    func testUnavailableUpdateCheckDoesNotReportEveryAppCurrent() {
        XCTAssertEqual(AppsUpdates.emptyStateMessage(updatesNote: nil), String(localized: "Every app is up to date."))
        for notice in ["Homebrew is not installed", "Homebrew check failed", "Synthetic provider unavailable"] {
            XCTAssertEqual(AppsUpdates.emptyStateMessage(updatesNote: notice), String(localized: "Could not check"))
        }
    }

    func testSpaceMapCanReserveBackShortcutWithoutRemovingStartOver() {
        var resets = 0
        let spaceMap = TopBarAction.startOver(bindBackShortcut: false) { resets += 1 }
        XCTAssertFalse(spaceMap.bindsBackShortcut)
        spaceMap.action()
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(TopBarAction.startOver({}).bindsBackShortcut)
        XCTAssertTrue(TopBarAction.back({}).bindsBackShortcut)
    }

    func testDisabledCategoryActionKeepsReviewAvailable() {
        var reviewed = false
        let card = CategoryCard(value: "0", caption: "tasks", symbol: "bolt", tint: .blue,
            actionTitle: "Run", review: { reviewed = true }, action: {},
            actionEnabled: false, actionDisabledReason: "No tasks")
        XCTAssertFalse(card.actionEnabled)
        XCTAssertEqual(card.actionDisabledReason, "No tasks")
        card.review()
        XCTAssertTrue(reviewed)
    }
}
