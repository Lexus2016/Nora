import Foundation
import Testing
@testable import MoleKit

struct UninstallParsingTests {
    // Screens captured from `mo uninstall --dry-run NoraFixtureQ7` (Mole 1.59.1, sandbox home).
    @Test func parsesMatches() {
        let lines = [
            "◎ Matched 1 app(s):",
            "1. NoraFixtureQ7  8KB  |  Last: Today",
            "Proceed with uninstallation? [y/N]",
        ]
        #expect(UninstallDriver.parseMatches(lines) == ["NoraFixtureQ7"])
    }

    @Test func parsesRemovalPlan() {
        let lines = [
            "Files to be removed:",
            "",
            "◎ NoraFixtureQ7 , 315KB",
            "  ✓ ~/Applications/NoraFixtureQ7.app , 8KB",
            "  ✓ ~/Library/Application Support/com.nora.fixture.q7 , 201KB",
            "  ✓ ~/Library/Caches/com.nora.fixture.q7 , 102KB",
            "",
            "➤ Remove 1 app, 315KB  Enter confirm, ESC cancel:",
        ]
        #expect(RemovalList(lines) == RemovalList(
            groups: ["NoraFixtureQ7"],
            entries: [
                "~/Applications/NoraFixtureQ7.app",
                "~/Library/Application Support/com.nora.fixture.q7",
                "~/Library/Caches/com.nora.fixture.q7",
            ]
        ))
    }
}

@Suite(.enabled(if: MoleE2E.enabled), .serialized)
struct UninstallE2ETests {
    private static let name = "NoraFixtureQ7"
    private static let bundleID = "com.nora.fixture.q7"
    private static let entries: Set = [
        "~/Applications/\(name).app",
        "~/Library/Application Support/\(bundleID)",
        "~/Library/Caches/\(bundleID)",
        "~/Library/Preferences/\(bundleID).plist",
    ]

    /// An app bundle with a collision-proof name and bundle id, plus three leftovers, all in the sandbox.
    private func makeHome() throws -> URL {
        let home = try TestSandbox.make("uninstall")
        let contents = home.appendingPathComponent("Applications/\(Self.name).app/Contents")
        try TestSandbox.write("#!/bin/sh\n", to: contents.appendingPathComponent("MacOS/\(Self.name)"))
        try TestSandbox.write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(Self.bundleID)</string>
            <key>CFBundleName</key><string>\(Self.name)</string>
            <key>CFBundleExecutable</key><string>\(Self.name)</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """, to: contents.appendingPathComponent("Info.plist"))
        try TestSandbox.writeRandom(bytes: 200_000, to: home.appendingPathComponent("Library/Application Support/\(Self.bundleID)/data.bin"))
        try TestSandbox.writeRandom(bytes: 100_000, to: home.appendingPathComponent("Library/Caches/\(Self.bundleID)/cache.bin"))
        try TestSandbox.write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict/></plist>
            """, to: home.appendingPathComponent("Library/Preferences/\(Self.bundleID).plist"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        return home
    }

    private func present(in home: URL) -> Set<String> {
        Set(Self.entries.filter {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(String($0.dropFirst(2))).path)
        })
    }

    private func session(_ home: URL) throws -> PTYSession {
        let mo = try #require(MoleE2E.executable)
        return try PTYSession(
            executable: mo.path, arguments: ["uninstall", "--permanent", Self.name],
            environment: MoleE2E.environment(home: home, noAuth: true), currentDirectory: home.path
        )
    }

    @Test func removesTheAppAndExactlyItsLeftovers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(present(in: home) == Self.entries)

        let session = try session(home)
        defer { session.close() }
        try UninstallDriver().uninstall(app: Self.name, expectedEntries: Self.entries, in: session)
        #expect(try session.waitForExit(timeout: 120) == .exited(0))
        #expect(present(in: home).isEmpty)
        #expect(session.unknownSequences.isEmpty)

        let mo = try #require(MoleE2E.executable)
        let version = try MoleInstallation(executable: mo).version(environment: MoleE2E.environment(home: home))
        try MoleE2E.recordFixture(session.transcriptBytes, name: "uninstall-fixture-app.transcript", version: version, home: home)
    }

    @Test func cancelsWhenThePlanHasAnUnexpectedPath() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var previewed = Self.entries
        previewed.remove("~/Library/Caches/\(Self.bundleID)")

        let session = try session(home)
        defer { session.close() }
        #expect(throws: UninstallDriverError.planMismatch(unexpected: ["~/Library/Caches/\(Self.bundleID)"], missing: [])) {
            try UninstallDriver().uninstall(app: Self.name, expectedEntries: previewed, in: session)
        }
        _ = try session.waitForExit(timeout: 60)
        #expect(present(in: home) == Self.entries)
    }
}
