import XCTest
@testable import Nora

final class SecurityParserTests: XCTestCase {
    func testClamScanReadsFoundLines() {
        let text = """
        /fixture/Downloads/sample.bin: Win.Test.EICAR_HDB-1 FOUND
        /fixture/Downloads/with: colon.zip: Fixture.Signature FOUND
        """
        let output = ClamScanParser.parse(text)
        XCTAssertEqual(output.detections, [
            ClamScanParser.Detection(path: "/fixture/Downloads/sample.bin", signature: "Win.Test.EICAR_HDB-1"),
            ClamScanParser.Detection(path: "/fixture/Downloads/with: colon.zip", signature: "Fixture.Signature"),
        ])
        XCTAssertEqual(output.errors, 0)
    }

    func testCleanAndErrorLinesAreNotDetections() {
        let text = """
        /fixture/a.txt: OK
        ERROR: Can't access file /fixture/locked
        /fixture/b.txt: Permission denied. ERROR
        """
        let output = ClamScanParser.parse(text)
        XCTAssertTrue(output.detections.isEmpty)
        XCTAssertEqual(output.errors, 2)
    }

    func testFoundLineWithoutPathIsIgnored() {
        XCTAssertTrue(ClamScanParser.parse(": Fixture.Signature FOUND").detections.isEmpty)
        XCTAssertTrue(ClamScanParser.parse("").detections.isEmpty)
    }

    func testClamScanArgumentsUseNoraDatabaseAndInfectedOnly() {
        let arguments = ClamScanParser.arguments(database: URL(fileURLWithPath: "/fixture/db"), roots: ["/fixture/a", "/fixture/b"])
        XCTAssertEqual(arguments, ["-r", "--infected", "--no-summary", "-d", "/fixture/db", "/fixture/a", "/fixture/b"])
    }

    func testYaraParsesMatchLinesOnly() {
        let text = """
        XProtectFixtureRule /fixture/Downloads/bad file.bin
        warning: something noisy
        not a match
        _Rule2 /fixture/other
        Rule3 relative/path
        """
        XCTAssertEqual(YaraParser.parse(text), [
            YaraParser.Match(rule: "XProtectFixtureRule", path: "/fixture/Downloads/bad file.bin"),
            YaraParser.Match(rule: "_Rule2", path: "/fixture/other"),
        ])
    }

    func testYaraArgumentsAreRecursiveAndQuiet() {
        let arguments = XProtect.arguments(rules: URL(fileURLWithPath: "/fixture/rules.yara"), root: "/fixture/root")
        XCTAssertEqual(arguments, ["-r", "-w", "/fixture/rules.yara", "/fixture/root"])
    }
}
