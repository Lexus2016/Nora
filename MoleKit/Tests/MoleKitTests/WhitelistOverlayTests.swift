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
}
