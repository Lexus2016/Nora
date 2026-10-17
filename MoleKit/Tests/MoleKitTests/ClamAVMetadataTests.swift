import Foundation
import XCTest
@testable import MoleKit

final class ClamAVMetadataTests: XCTestCase {
    func testEngineAndDefinitionsHaveSeparateVersions() throws {
        let info = try XCTUnwrap(ClamAVVersionInfo.parse("ClamAV 1.4.3/28000/Sat Oct 17 10:20:30 2026\n"))
        XCTAssertEqual(info.engine, "1.4.3")
        XCTAssertEqual(info.databaseVersion, "28000")
        XCTAssertEqual(info.databaseDate, ISO8601DateFormatter().date(from: "2026-10-17T10:20:30Z"))
    }

    func testEngineOnlyIsNotEvidenceOfDefinitions() throws {
        let info = try XCTUnwrap(ClamAVVersionInfo.parse("ClamAV 1.4.3\n"))
        XCTAssertNil(info.databaseVersion)
        XCTAssertNil(info.databaseDate)
        XCTAssertNil(ClamAVVersionInfo.parse(""))
        XCTAssertNil(ClamAVVersionInfo.parse("permission denied"))
        XCTAssertNil(ClamAVVersionInfo.parse("ClamAV unknown"))
        XCTAssertNil(ClamAVVersionInfo.parse("ClamAV 1.4.3\nClamAV 1.5.0"))
    }

    func testBrokenDateDoesNotBecomeFresh() throws {
        let info = try XCTUnwrap(ClamAVVersionInfo.parse("ClamAV 1.4.3/28000/not a date"))
        XCTAssertEqual(info.databaseVersion, "28000")
        XCTAssertNil(info.databaseDate)
    }

    func testFreshnessUsesHeaderAgeRatherThanLastDownloadAttempt() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(ClamAVVersionInfo.freshness(hasDatabase: false, builtAt: now, now: now), .missing)
        XCTAssertEqual(ClamAVVersionInfo.freshness(hasDatabase: true, builtAt: nil, now: now), .unknown)
        XCTAssertEqual(ClamAVVersionInfo.freshness(hasDatabase: true, builtAt: now.addingTimeInterval(301), now: now), .unknown)
        XCTAssertEqual(ClamAVVersionInfo.freshness(hasDatabase: true, builtAt: now.addingTimeInterval(-48 * 3_600 + 1), now: now), .recent)
        XCTAssertEqual(ClamAVVersionInfo.freshness(hasDatabase: true, builtAt: now.addingTimeInterval(-48 * 3_600), now: now), .old)
    }

    func testHomebrewPackageRevisionAndOutdatedFlagArePreserved() throws {
        let data = Data(#"{"formulae":[{"name":"clamav","versions":{"stable":"1.4.3"},"revision":2,"installed":[{"version":"1.4.3_1"}],"outdated":true,"pinned":false}]}"#.utf8)
        let info = try ClamAVFormulaInfo.parse(data)
        XCTAssertEqual(info.version, "1.4.3")
        XCTAssertEqual(info.packageVersion, "1.4.3_2")
        XCTAssertTrue(info.outdated)
        XCTAssertFalse(info.hasVerifiedPackage)
    }

    func testMissingMalformedOrForeignCatalogCannotSayUpToDate() {
        for text in ["{}", #"{"formulae":[]}"#,
                     #"{"formulae":[{"name":"yara","versions":{"stable":"1.4.3"},"revision":0,"installed":[],"outdated":false}]}"#,
                     #"{"formulae":[{"name":"clamav","versions":{"stable":null},"revision":0,"installed":[],"outdated":false}]}"#,
                     #"{"formulae":[{"name":"clamav","versions":{"stable":"1.4.3"},"revision":0,"installed":[]}]}"#] {
            XCTAssertThrowsError(try ClamAVFormulaInfo.parse(Data(text.utf8)))
        }
    }

    func testPackageMustBePresentToVerifySuccessfulUpgrade() throws {
        let missing = Data(#"{"formulae":[{"name":"clamav","versions":{"stable":"1.4.3"},"revision":0,"installed":[],"outdated":false}]}"#.utf8)
        XCTAssertFalse(try ClamAVFormulaInfo.parse(missing).hasVerifiedPackage)
        let present = Data(#"{"formulae":[{"name":"clamav","versions":{"stable":"1.4.3"},"revision":0,"installed":[{"version":"1.4.3"}],"outdated":false}]}"#.utf8)
        XCTAssertTrue(try ClamAVFormulaInfo.parse(present).hasVerifiedPackage)
    }

    func testEngineCommandsCannotBecomeDefinitionOrBroadUpgradeCommands() {
        XCTAssertEqual(ClamAVFormulaInfo.checkArguments, ["info", "--json=v2", "--formula", "clamav"])
        XCTAssertEqual(ClamAVFormulaInfo.upgradeArguments, ["upgrade", "--formula", "clamav"])
        XCTAssertFalse(ClamAVFormulaInfo.upgradeArguments.contains("--cask"))
    }
}
