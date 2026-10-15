import Foundation
import Testing
@testable import MoleKit

struct WhitelistOverlayTests {
    private func overlay(_ home: URL) -> WhitelistOverlay {
        WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("support/whitelist-journal.json"))
    }

    private func contents(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// While a run's overlay is applied, editors must see the user's own list, never the run's
    /// temporary entries (they would be saved back as permanent rules).
    @Test func userWhitelistIgnoresTheActiveOverlay() throws {
        let home = try TestSandbox.make("wl-user")
        defer { try? FileManager.default.removeItem(at: home) }
        let o = overlay(home)
        try TestSandbox.write("~/Keep\n", to: o.whitelistURL)
        try o.apply(protecting: ["/tmp/run-only"], defaults: [], runID: "r1")
        #expect(contents(o.whitelistURL)?.contains("/tmp/run-only") == true)
        #expect(o.userWhitelist() == "~/Keep\n")
        try o.recover(runID: "r1")
        #expect(o.userWhitelist() == "~/Keep\n")

        let bare = try TestSandbox.make("wl-user-absent")
        defer { try? FileManager.default.removeItem(at: bare) }
        let none = overlay(bare)
        try none.apply(protecting: ["/tmp/run-only"], defaults: ["~/Default"], runID: "r2")
        #expect(none.userWhitelist() == nil, "no whitelist file before the run means none for the editor")
        try none.recover(runID: "r2")
    }

    @Test func absentOriginalMaterializesDefaultsAndIsDeletedOnRestore() throws {
        let home = try TestSandbox.make("wl-absent")
        defer { try? FileManager.default.removeItem(at: home) }
        let overlay = overlay(home)

        try overlay.apply(protecting: ["~/Keep/*"], defaults: ["~/.ollama/models/*"], runID: "r1")
        let written = try #require(contents(overlay.whitelistURL))
        #expect(written.contains("~/.ollama/models/*\n"))
        #expect(written.contains("# >>> nora-overlay r1\n~/Keep/*\n# <<< nora-overlay r1\n"))
        #expect(overlay.needsRecovery)

        try overlay.recoverIfNeeded()
        // An empty file would silently replace Mole's defaults, so absent must stay absent.
        #expect(!FileManager.default.fileExists(atPath: overlay.whitelistURL.path))
        #expect(!overlay.needsRecovery)
    }

    @Test(arguments: ["~/mine/*\n# note\n", "~/no-trailing-newline/*", ""])
    func presentOriginalIsRestoredByteForByte(original: String) throws {
        let home = try TestSandbox.make("wl-present")
        defer { try? FileManager.default.removeItem(at: home) }
        let overlay = overlay(home)
        try TestSandbox.write(original, to: overlay.whitelistURL)

        try overlay.apply(protecting: ["~/Keep/*"], defaults: ["~/ignored-default/*"], runID: "r2")
        let written = try #require(contents(overlay.whitelistURL))
        #expect(written.hasPrefix(original))
        #expect(!written.contains("ignored-default"))
        #expect(written.hasSuffix("# >>> nora-overlay r2\n~/Keep/*\n# <<< nora-overlay r2\n"))

        try overlay.recoverIfNeeded()
        #expect(contents(overlay.whitelistURL) == original)
    }

    @Test func refusesToStackOnAnUnrecoveredRun() throws {
        let home = try TestSandbox.make("wl-stack")
        defer { try? FileManager.default.removeItem(at: home) }
        let overlay = overlay(home)

        try overlay.apply(protecting: ["~/a/*"], defaults: [], runID: "r1")
        #expect(throws: WhitelistOverlayError.pendingRecovery) {
            try overlay.apply(protecting: ["~/b/*"], defaults: [], runID: "r2")
        }
    }

    @Test func writesThroughASymlinkedWhitelist() throws {
        let home = try TestSandbox.make("wl-symlink")
        defer { try? FileManager.default.removeItem(at: home) }
        let overlay = overlay(home)
        let real = home.appendingPathComponent("dotfiles/mole-whitelist")
        try TestSandbox.write("~/dotfiles-entry/*\n", to: real)
        try FileManager.default.createDirectory(
            at: overlay.whitelistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: overlay.whitelistURL, withDestinationURL: real)

        try overlay.apply(protecting: ["~/Keep/*"], defaults: [], runID: "r3")
        #expect(contents(real)?.contains("~/Keep/*") == true)
        try overlay.recoverIfNeeded()

        #expect(contents(real) == "~/dotfiles-entry/*\n")
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: overlay.whitelistURL.path)
        #expect(link == real.path)
    }

    /// The M0 acceptance case: SIGKILL right after the overlay lands, then recover on "next launch".
    @Test(arguments: [String?.none, "~/mine/*\n"])
    func recoversAfterKill9(original: String?) throws {
        let spike = try #require(SpikeBinary.url, "build molekit-spike first (swift build)")
        let home = try TestSandbox.make("wl-kill")
        defer { try? FileManager.default.removeItem(at: home) }
        let overlay = overlay(home)
        if let original { try TestSandbox.write(original, to: overlay.whitelistURL) }

        let process = Process()
        process.executableURL = spike
        process.arguments = ["overlay-apply", home.path, overlay.journalURL.path, "~/Keep/*"]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        let ready = stdout.fileHandleForReading.availableData
        #expect(String(decoding: ready, as: UTF8.self).contains("applied"))

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(contents(overlay.whitelistURL)?.contains("~/Keep/*") == true)
        #expect(overlay.needsRecovery)

        try overlay.recoverIfNeeded()
        #expect(contents(overlay.whitelistURL) == original)
        #expect(!overlay.needsRecovery)
    }
}

/// Checks the overlay against Mole's own `load_mole_whitelist` / `is_path_whitelisted`.
@Suite(.enabled(if: MoleE2E.enabled))
struct WhitelistOverlayMoleTests {
    @Test func overlayProtectsTheNewPathAndKeepsMoleDefaults() throws {
        let home = try TestSandbox.make("wl-mole")
        defer { try? FileManager.default.removeItem(at: home) }
        let mole = try MoleInstallation(executable: try #require(MoleE2E.executable))
        let overlay = WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("support/journal.json"))

        let defaults = try mole.cleanWhitelistDefaults(home: home)
        #expect(defaults.contains("\(home.path)/.ollama/models/*"))

        let defaultProtected = "\(home.path)/.ollama/models/blobs/x"
        let unchecked = "\(home.path)/Library/Caches/com.example.NoraKeep/data"
        #expect(try mole.protects(defaultProtected, home: home))
        #expect(try !mole.protects(unchecked, home: home))

        try overlay.apply(protecting: ["\(home.path)/Library/Caches/com.example.NoraKeep/*"], defaults: defaults, runID: "e2e")
        #expect(try mole.protects(unchecked, home: home))
        #expect(try mole.protects(defaultProtected, home: home))

        try overlay.recoverIfNeeded()
        #expect(!FileManager.default.fileExists(atPath: overlay.whitelistURL.path))
        #expect(try mole.protects(defaultProtected, home: home))
        #expect(try !mole.protects(unchecked, home: home))
    }

    /// Mole's loader rejects any rule containing `..` and trims surrounding spaces, so these
    /// literal paths stay unprotected however the overlay writes them. `unprotected` must say so.
    @Test func reportsLiteralPathsMoleCannotProtect() throws {
        let home = try TestSandbox.make("wl-literal")
        defer { try? FileManager.default.removeItem(at: home) }
        let mole = try MoleInstallation(executable: try #require(MoleE2E.executable))
        let overlay = WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("support/journal.json"))

        let plain = "\(home.path)/Projects/alpha/node_modules"
        let spaced = "\(home.path)/Projects/my app/node_modules"
        let dots = "\(home.path)/Projects/client..archive/node_modules"
        let trailing = "\(home.path)/Library/Caches/com.example.trailing "
        let glob = "\(home.path)/Library/Caches/com.example.[keep]"
        let paths = [plain, spaced, dots, trailing, glob]
        try overlay.apply(protecting: paths, defaults: try mole.cleanWhitelistDefaults(home: home), runID: "literal")
        defer { try? overlay.recoverIfNeeded() }

        #expect(try mole.unprotected(paths, home: home) == [dots, trailing])
        #expect(try mole.unprotected([], home: home) == [])
    }

    /// A category's Clean protects every item of the other categories, so a long list is normal.
    /// 1,500 rules took over two minutes through `is_path_whitelisted` alone. Mole's own loader
    /// is quadratic too, and `mo clean` pays it as well; the check must cost about one load.
    @Test func checksALongProtectedListQuickly() throws {
        let home = try TestSandbox.make("wl-long")
        defer { try? FileManager.default.removeItem(at: home) }
        let mole = try MoleInstallation(executable: try #require(MoleE2E.executable))
        let overlay = WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("support/journal.json"))
        let dots = "\(home.path)/Projects/client..archive/node_modules"
        let paths = (0..<1500).map { "\(home.path)/Library/Caches/com.example.app\($0)/data" } + [dots, "\(home.path)/Library/Caches/slash/"]
        try overlay.apply(protecting: paths, defaults: try mole.cleanWhitelistDefaults(home: home), runID: "long")
        defer { try? overlay.recoverIfNeeded() }
        var started = Date()
        _ = try mole.unprotected([paths[0]], home: home)
        let oneLoad = Date().timeIntervalSince(started)
        started = Date()
        #expect(try mole.unprotected(paths, home: home) == [dots])
        let check = Date().timeIntervalSince(started)
        #expect(check < oneLoad * 1.5 + 2, "check \(check) s, one load \(oneLoad) s")
    }
}
