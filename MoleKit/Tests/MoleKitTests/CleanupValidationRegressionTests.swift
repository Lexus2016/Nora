import Foundation
import XCTest
@testable import MoleKit

/// Synthetic text only. No cleanup command, user data, or privileged process is used.
final class CleanupValidationRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let output = "Dry run complete - no changes made\nPotential space: 2MB | Items: 25\nDetailed file list: synthetic"
    private let list = "=== Caches ===\n/Users/example/Library/Caches/Synthetic  # 2MB, 25 items\n"

    func testAggregateFileCountIsNotPathRowCount() {
        let preview = CleanPreview.validated(stdout: output, list: list, listModified: now, since: now)
        XCTAssertEqual(preview?.items.count, 1)
        XCTAssertEqual(preview?.reportedItemCount, 25)
        XCTAssertEqual(preview?.isComplete, true)
    }

    func testMalformedOrMissingListFailsClosed() {
        for value: String? in [nil, "", "=== Caches ===\n", list + "unrecognized record\n", list + "/Users/example/other  # unsupported\n"] {
            XCTAssertNil(CleanPreview.validated(stdout: output, list: value, listModified: now, since: now))
        }
        let parsed = CleanPreview.parse(cleanList: list + "unrecognized record\n", stdout: output)
        XCTAssertEqual(parsed.unparsedRows, ["unrecognized record"])
        XCTAssertFalse(parsed.isComplete, "Parsing alone must never authorize a cleanup")
    }

    func testAmbiguousSizeLikeFilenamesAndUnknownAnnotationsFailClosed() {
        for row in [
            "/Users/example/cache  # 2MB, suffix  # 5MB",
            "/Users/example/cache  # size unknown, suffix  # 5MB",
            "/Users/example/cache  # 2MB, unrecognized annotation"
        ] {
            XCTAssertNil(CleanPreview.validated(stdout: output, list: "=== Caches ===\n" + row,
                                                listModified: now, since: now))
        }
    }

    func testDuplicateAndUnsectionedPathsFailClosed() {
        XCTAssertNil(CleanPreview.validated(stdout: output, list: list + list, listModified: now, since: now))
        XCTAssertNil(CleanPreview.validated(stdout: output, list: "/Users/example/cache  # 2MB", listModified: now, since: now))
    }

    func testCompletionFreshnessAndPositiveEmptyAreRequired() {
        XCTAssertNil(CleanPreview.validated(stdout: output, list: list, listModified: now.addingTimeInterval(-1), since: now))
        XCTAssertNil(CleanPreview.validated(stdout: output, list: list, listModified: nil, since: now))
        XCTAssertNil(CleanPreview.validated(stdout: output.replacingOccurrences(of: "Dry run complete", with: "Dry run incomplete"), list: list, listModified: now, since: now))
        XCTAssertNil(CleanPreview.validated(stdout: "Dry run complete", list: nil, listModified: nil, since: now))
        XCTAssertNil(CleanPreview.validated(stdout: "Dry run complete\nPotential space: 2MB | Items: 25", list: nil, listModified: nil, since: now))
        XCTAssertEqual(CleanPreview.validated(stdout: "Dry run complete\nNo significant reclaimable space detected, system already clean.", list: nil, listModified: nil, since: now)?.items.count, 0)
    }

    func testInvalidNumericSizesDoNotTrap() {
        for value in ["nanGB", "infGB", "-1GB", "999999999999999999999999TB"] {
            XCTAssertNil(MoleSize.parse(value))
        }
    }

    func testGatedResultContainsOnlyExecutionPhase() {
        let check = "=====\nDry run complete\nPotential space: 2GB\n=====\n"
        let result = PTYRun.Result(status: .exited(0), text: check + PrivilegeBroker.runMarker + "\nno execution summary")
        XCTAssertEqual(result.runPhaseResult().text, "no execution summary")
        XCTAssertEqual(PTYRun.Result(status: .exited(0), text: check).runPhaseResult().text, "")
    }

    func testInstallerEarlyExitNeedsExplicitEmptySuccess() {
        XCTAssertFalse(InstallerDriver.isEmptyScan(status: .exited(1), output: "No installers found"))
        XCTAssertFalse(InstallerDriver.isEmptyScan(status: .exited(0), output: "unexpected output"))
        XCTAssertTrue(InstallerDriver.isEmptyScan(status: .exited(0), output: "No installer files found."))
        XCTAssertTrue(InstallerDriver.isEmptyScan(status: .exited(0), output: "✓ Great! No installer files to clean"))
        XCTAssertFalse(InstallerDriver.isEmptyScan(status: .exited(1), output: "✓ Great! No installer files to clean"))
        XCTAssertFalse(InstallerDriver.isEmptyScan(status: .exited(0), output: "DRY RUN MODE, No installer files will be removed"))
    }
}
