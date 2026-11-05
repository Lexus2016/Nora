import XCTest
@testable import MoleKit

/// Mole's built-in time limits suit a terminal user who can simply run a slow step again. A
/// preview Nora shows for review must not silently lose Homebrew or a large projects folder
/// because it took longer than a few seconds (measured: 22-24 s against 6 s and 20 s), and a
/// project preview that did not finish is refused by Nora, so its artifacts can never be cleaned.
final class MoleLimitsTests: XCTestCase {
    func testCleanGetsLongerLimitsThanMoleDefaults() {
        let limits = Mole.scanLimits(for: ["clean", "--dry-run"])
        XCTAssertEqual(limits["MOLE_PROJECT_CACHE_SCAN_TIMEOUT"], "60")
        XCTAssertEqual(limits["MOLE_TIMEOUT_PKG_CLEANUP_SEC"], "60")
        XCTAssertEqual(Mole.scanLimits(for: ["clean"]), limits, "the real run must use the same limits as its preview")
    }

    /// Measured on a real projects folder: with Mole's 60 s and 15 s, `~/_Projects` ended with status
    /// 124 and the preview read "Dry run incomplete" (5.58GB, that root skipped); with 240 s and 60 s
    /// it read "Dry run complete" (4.89GB, 382 artifacts).
    func testPurgeGetsLimitsThatLetItFinishItsScan() {
        let limits = Mole.scanLimits(for: ["purge", "--dry-run"])
        XCTAssertEqual(limits["MO_PURGE_SCAN_TIMEOUT_SEC"], "240")
        XCTAssertEqual(limits["MO_PURGE_SIZE_TIMEOUT_SEC"], "60")
        XCTAssertEqual(Mole.scanLimits(for: ["purge", "--yes"]), limits, "the real run must use the same limits as its preview")
        XCTAssertNil(limits["MOLE_PROJECT_CACHE_SCAN_TIMEOUT"], "purge has limits of its own")
    }

    func testOtherCommandsKeepMolesOwnLimits() {
        XCTAssertTrue(Mole.scanLimits(for: ["uninstall", "--list"]).isEmpty)
        XCTAssertTrue(Mole.scanLimits(for: ["optimize", "--dry-run"]).isEmpty)
        XCTAssertTrue(Mole.scanLimits(for: []).isEmpty)
    }
}
