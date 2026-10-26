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

    @Test func truncatedRowsMatchByPrefix() {
        let row = InstallerRow(isCursor: false, isSelected: false, name: "NoraQ7-VeryLongIns...", size: "400KB", source: "Downloads")
        #expect(InstallerDriver.row(row, shows: "NoraQ7-VeryLongInstallerName-v1.2.3-arm64.dmg"))
        #expect(!InstallerDriver.row(row, shows: "NoraQ7-Other.dmg"))
        let full = InstallerRow(isCursor: false, isSelected: false, name: "NoraQ7-1.dmg", size: "1MB", source: "Downloads")
        #expect(!InstallerDriver.row(full, shows: "NoraQ7-1.dmg.bak"))
    }
}

@Suite(.enabled(if: MoleE2E.enabled), .serialized)
struct InstallerE2ETests {
    private let fixtures = [
        "Downloads/NoraQ7-1.dmg", "Downloads/NoraQ7-2.dmg", "Downloads/NoraQ7-3.pkg",
        "Desktop/NoraQ7-4.pkg", "Desktop/NoraQ7-5.dmg",
    ]

    private static let longName = "NoraQ7-VeryLongInstallerName-ForTruncationProbe-v1.2.3-arm64.dmg"

    private func makeHome(extra: [String] = []) throws -> URL {
        let home = try TestSandbox.make("installer")
        for (index, path) in (fixtures + extra).enumerated() {
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

    /// Nora sets `MOLE_DELETE_MODE=trash`, undocumented in 1.59.1; this guards that `mo installer`
    /// still routes through `mole_delete` to the Trash. `MOLE_TEST_TRASH_DIR` is Mole's own
    /// test switch that turns the Trash move into a `mv` into a sandbox folder.
    @Test func trashModeMovesFilesToTheTrash() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)
        let trash = home.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var env = MoleE2E.environment(home: home)
        env["MOLE_TEST_NO_AUTH"] = "1"
        env["MOLE_DELETE_MODE"] = "trash"
        env["MOLE_TEST_TRASH_DIR"] = trash.path

        let session = try PTYSession(executable: mo.path, arguments: ["installer"], environment: env, currentDirectory: home.path)
        defer { session.close() }
        try InstallerDriver().delete(["NoraQ7-2.dmg"], allowedSources: ["Downloads"], in: session)
        #expect(try session.waitForExit(timeout: 60) == .exited(0))
        #expect(!remaining(in: home).contains("NoraQ7-2.dmg"))
        let trashed = (try? FileManager.default.subpathsOfDirectory(atPath: trash.path)) ?? []
        let log = (try? String(contentsOf: home.appendingPathComponent("Library/Logs/mole/deletions.log"), encoding: .utf8)) ?? "no log"
        // Mole's test Trash names the moved file "<name>.<pid>.<time>".
        #expect(trashed.contains { $0.hasPrefix("NoraQ7-2.dmg.") }, "trash folder: \(trashed)")
        #expect(log.contains("\ttrash\t") && log.contains("\tok\t"), "deletions.log: \(log)")
    }

    @Test func deletesOnlySelectedSameNamedCopies() throws {
        let copies = (1...3).map { "Downloads/0\($0)/Example.dmg" }
        let home = try makeHome(extra: copies)
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)
        let env = MoleE2E.environment(home: home, noAuth: true)

        let listing = try PTYSession(executable: mo.path, arguments: ["installer", "--dry-run"],
                                     environment: env, currentDirectory: home.path)
        defer { listing.close() }
        let rows = try InstallerDriver().list(in: listing).filter { $0.name == "Example.dmg" }
        _ = try listing.waitForExit(timeout: 30)
        #expect(rows.count == 3)
        let targets = rows.prefix(2).map { InstallerTarget(name: $0.name, sources: [$0.source], size: $0.size) }

        let session = try PTYSession(executable: mo.path, arguments: ["installer"],
                                     environment: env, currentDirectory: home.path)
        defer { session.close() }
        try InstallerDriver().delete(targets, in: session)
        #expect(try session.waitForExit(timeout: 60) == .exited(0))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(copies[0]).path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(copies[1]).path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(copies[2]).path))
        #expect(remaining(in: home).count == fixtures.count)
    }

    @Test func listsTheMenuOfADryRun() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)
        let session = try PTYSession(executable: mo.path, arguments: ["installer", "--dry-run"],
                                     environment: MoleE2E.environment(home: home), currentDirectory: home.path)
        defer { session.close() }
        let rows = try InstallerDriver().list(in: session)
        #expect(Set(rows.map(\.name)) == Set(fixtures.map { URL(fileURLWithPath: $0).lastPathComponent }))
        _ = try session.waitForExit(timeout: 30)
        #expect(remaining(in: home).count == fixtures.count)
    }

    /// Real installer names usually exceed the menu column and show as "Prefix...".
    @Test func deletesATruncatedLongName() throws {
        let home = try makeHome(extra: ["Downloads/\(Self.longName)"])
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)

        let session = try PTYSession(
            executable: mo.path, arguments: ["installer"],
            environment: MoleE2E.environment(home: home), currentDirectory: home.path
        )
        defer { session.close() }

        try InstallerDriver().delete([Self.longName, "NoraQ7-1.dmg"], allowedSources: ["Downloads"], in: session)
        #expect(try session.waitForExit(timeout: 60) == .exited(0))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Downloads/\(Self.longName)").path))
        #expect(remaining(in: home) == ["NoraQ7-2.dmg", "NoraQ7-3.pkg", "NoraQ7-4.pkg", "NoraQ7-5.dmg"])
    }

    /// The app's path: names come from the dry-run menu (cut with "..."), each with its source.
    @Test func deletesWhatTheDryRunMenuListed() throws {
        let home = try makeHome(extra: ["Downloads/\(Self.longName)"])
        defer { try? FileManager.default.removeItem(at: home) }
        let mo = try #require(MoleE2E.executable)
        let env = MoleE2E.environment(home: home)

        let listing = try PTYSession(executable: mo.path, arguments: ["installer", "--dry-run"], environment: env, currentDirectory: home.path)
        let rows = try InstallerDriver().list(in: listing)
        _ = try listing.waitForExit(timeout: 30)
        listing.close()
        let long = try #require(rows.first { $0.name.hasSuffix("...") && Self.longName.hasPrefix(String($0.name.dropLast(3))) })
        let short = try #require(rows.first { $0.name == "NoraQ7-1.dmg" })

        let session = try PTYSession(executable: mo.path, arguments: ["installer"], environment: env, currentDirectory: home.path)
        defer { session.close() }
        try InstallerDriver().delete([long, short].map { InstallerTarget(name: $0.name, sources: [$0.source]) }, in: session)
        #expect(try session.waitForExit(timeout: 60) == .exited(0))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Downloads/\(Self.longName)").path))
        #expect(remaining(in: home) == ["NoraQ7-2.dmg", "NoraQ7-3.pkg", "NoraQ7-4.pkg", "NoraQ7-5.dmg"])
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

struct InstallerReviewMatchTests {
    @Test func repeatedBasenamesMatchDistinctSelectedFiles() {
        let download = InstallerTarget(name: "Example.dmg", sources: ["Downloads"], size: "1MB")
        let desktop = InstallerTarget(name: "Example.dmg", sources: ["Desktop"], size: "2MB")
        #expect(InstallerDriver.review(["Example.dmg", "Example.dmg"], matches: [download, desktop]))
        #expect(!InstallerDriver.review(["Example.dmg"], matches: [download, desktop]))
        #expect(!InstallerDriver.review(["Example.dmg", "Other.dmg"], matches: [download, desktop]))
        let other = InstallerTarget(name: "Other.dmg", sources: ["Downloads"])
        #expect(!InstallerDriver.review(["Example.dmg", "Other.dmg", "Other.dmg"], matches: [download, desktop, other]))
    }

    @Test func cutNamesStillRefuseDifferentMatchingFullNames() {
        let download = InstallerTarget(name: "Example...", sources: ["Downloads"], size: "1MB")
        let desktop = InstallerTarget(name: "Example...", sources: ["Desktop"], size: "2MB")
        #expect(!InstallerDriver.review(["Example-1.dmg", "Example-2.dmg"], matches: [download, desktop]))
    }

    /// The menu cuts long names; the review prints them in full. One to one, nothing left over.
    @Test func reviewMatchesCutMenuNamesOneToOne() {
        let long = "Some-Very-Long-Installer-Name-For-Testing-1.2.3-universal.dmg"
        let cut = String(long.prefix(37)) + "..."
        let target = InstallerTarget(name: cut, sources: ["Downloads"])
        #expect(InstallerDriver.review([long], matches: [target]))
        #expect(!InstallerDriver.review([long, "Other.dmg"], matches: [target]))
        #expect(!InstallerDriver.review(["Different.dmg"], matches: [target]))
        let twin = InstallerTarget(name: cut, sources: ["Desktop"])
        #expect(!InstallerDriver.review([long], matches: [target, twin]))
    }

    /// A different file behind the same cut name in the same folder must not stand in for the one
    /// the user saw: the size is part of what was reviewed.
    @Test func cutNameRowMustKeepTheReviewedSize() {
        let cut = "Some-Very-Long-Installer-Name-For-Tes..."
        let target = InstallerTarget(name: cut, sources: ["Downloads"], size: "1.5GB")
        let same = InstallerRow(isCursor: false, isSelected: false, name: cut, size: "1.5GB", source: "Downloads")
        let swapped = InstallerRow(isCursor: false, isSelected: false, name: cut, size: "1.6GB", source: "Downloads")
        let elsewhere = InstallerRow(isCursor: false, isSelected: false, name: cut, size: "1.5GB", source: "Desktop")
        #expect(InstallerDriver.row(same, is: target))
        #expect(!InstallerDriver.row(swapped, is: target))
        #expect(!InstallerDriver.row(elsewhere, is: target))
    }
}
