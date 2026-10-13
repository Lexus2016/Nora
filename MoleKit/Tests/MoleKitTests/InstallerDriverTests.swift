import Foundation
import Testing
@testable import MoleKit

struct InstallerParsingTests {
    // Screen captured from `mo installer` 1.59.1 in a sandbox home.
    private let menu = [
        "Select Installers to Remove , 1.5MB, 1 selected",
        "",
        "➤ ○ NoraQ7-4.pkg                                900KB | Desktop",
        "  ○ NoraQ7-1.dmg                                1.5MB | Downloads",
        "  ● NoraQ7-2.dmg                                1.5MB | Downloads",
        "",
        "↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit",
    ]

    @Test func parsesRows() {
        #expect(InstallerDriver.parseRows(menu) == [
            InstallerRow(isCursor: true, isSelected: false, name: "NoraQ7-4.pkg", size: "900KB", source: "Desktop"),
            InstallerRow(isCursor: false, isSelected: false, name: "NoraQ7-1.dmg", size: "1.5MB", source: "Downloads"),
            InstallerRow(isCursor: false, isSelected: true, name: "NoraQ7-2.dmg", size: "1.5MB", source: "Downloads"),
        ])
    }

    @Test func parsesReview() {
        let review = [
            "Files to be removed:",
            "  ✓ NoraQ7-2.dmg , 1.5MB",
            "  ✓ NoraQ7-4.pkg , 900KB",
            "",
            "➤ Delete 2 installers, 2.4MB  Enter confirm, ESC cancel:",
        ]
        #expect(InstallerDriver.parseReview(review) == ["NoraQ7-2.dmg", "NoraQ7-4.pkg"])
    }
}

@Suite(.enabled(if: MoleE2E.enabled), .serialized)
struct InstallerE2ETests {
    private let fixtures = [
        "Downloads/NoraQ7-1.dmg", "Downloads/NoraQ7-2.dmg", "Downloads/NoraQ7-3.pkg",
        "Desktop/NoraQ7-4.pkg", "Desktop/NoraQ7-5.dmg",
    ]

    private func makeHome() throws -> URL {
        let home = try TestSandbox.make("installer")
        for (index, path) in fixtures.enumerated() {
            try TestSandbox.writeRandom(bytes: 300_000 * (index + 1), to: home.appendingPathComponent(path))
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        return home
    }

    private func remaining(in home: URL) -> Set<String> {
        Set(fixtures.filter { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
            .map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    @Test func deletesExactlyTwoOfFive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)
        let version = try MoleInstallation(executable: mo).version(environment: MoleE2E.environment(home: home))

        let session = try PTYSession(
            executable: mo.path, arguments: ["installer"],
            environment: MoleE2E.environment(home: home), currentDirectory: home.path
        )
        defer { session.close() }

        let targets: Set = ["NoraQ7-2.dmg", "NoraQ7-4.pkg"]
        try InstallerDriver().delete(targets, allowedSources: ["Downloads", "Desktop"], in: session)
        #expect(try session.waitForExit(timeout: 60) == .exited(0))
        #expect(remaining(in: home) == ["NoraQ7-1.dmg", "NoraQ7-3.pkg", "NoraQ7-5.dmg"])
        #expect(session.unknownSequences.isEmpty)

        try MoleE2E.recordFixture(session.transcriptBytes, name: "installer-delete-2-of-5.transcript", version: version, home: home)
    }

    @Test func refusesWhenATargetIsMissingAndDeletesNothing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)

        let session = try PTYSession(
            executable: mo.path, arguments: ["installer"],
            environment: MoleE2E.environment(home: home), currentDirectory: home.path
        )
        defer { session.close() }

        #expect(throws: InstallerDriverError.targetNotListed("NoraQ7-9.dmg")) {
            try InstallerDriver().delete(["NoraQ7-2.dmg", "NoraQ7-9.dmg"], allowedSources: ["Downloads"], in: session)
        }
        _ = try session.waitForExit(timeout: 30)
        #expect(remaining(in: home).count == fixtures.count)
    }

    @Test func refusesASourceOutsideTheAllowedSet() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)

        let session = try PTYSession(
            executable: mo.path, arguments: ["installer"],
            environment: MoleE2E.environment(home: home), currentDirectory: home.path
        )
        defer { session.close() }

        #expect(throws: InstallerDriverError.sourceNotAllowed(name: "NoraQ7-4.pkg", source: "Desktop")) {
            try InstallerDriver().delete(["NoraQ7-4.pkg"], allowedSources: ["Downloads"], in: session)
        }
        _ = try session.waitForExit(timeout: 30)
        #expect(remaining(in: home).count == fixtures.count)
    }
}
