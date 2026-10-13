import XCTest
@testable import MoleKit

/// Custom purge selection without a menu driver: `mo purge` skips whitelisted artifacts
/// (`is_path_whitelisted` in lib/clean/project.sh), so unchecked artifacts are protected by
/// the whitelist overlay and the rest go through `mo purge --yes`.
final class PurgeOverlayTests: XCTestCase {
    func testOverlayProtectsUncheckedArtifactsFromPurgeYes() async throws {
        guard MoleE2E.enabled, let mo = MoleE2E.executable else { throw XCTSkip("set NORA_MOLE_E2E=1") }
        let home = try TestSandbox.make("purge")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("tmp"), withIntermediateDirectories: true)

        let projects = home.appendingPathComponent("Projects")
        let alpha = projects.appendingPathComponent("alpha/node_modules")
        let beta = projects.appendingPathComponent("beta/node_modules")
        let gamma = projects.appendingPathComponent("gamma/target")
        try TestSandbox.write("{}", to: projects.appendingPathComponent("alpha/package.json"))
        try TestSandbox.write("{}", to: projects.appendingPathComponent("beta/package.json"))
        try TestSandbox.write("[package]\nname = \"gamma\"\n", to: projects.appendingPathComponent("gamma/Cargo.toml"))
        for dir in [alpha, beta, gamma] {
            try TestSandbox.writeRandom(bytes: 200_000, to: dir.appendingPathComponent("blob.bin"))
        }
        // Mole leaves recently active projects alone; age everything by 90 days.
        let old = Date().addingTimeInterval(-90 * 86_400)
        let paths = FileManager.default.subpaths(atPath: projects.path) ?? []
        for path in paths { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: projects.appendingPathComponent(path).path) }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: projects.path)

        let env = MoleE2E.environment(home: home)
        let preview = try await ProcessRunner.run(mo, ["purge", "--dry-run"], environment: env)
        let parsed = PurgePreview.parse(preview.stdout, home: home)
        let found = Set(parsed.items.map(\.path))
        XCTAssertEqual(found, [alpha.path, beta.path, gamma.path], preview.stdout)

        let installation = try MoleInstallation(executable: mo)
        let overlay = WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("journal.json"))
        try overlay.apply(protecting: [beta.path], defaults: try installation.cleanWhitelistDefaults(home: home), runID: "purge-test")
        let run = try await ProcessRunner.run(mo, ["purge", "--yes"], environment: env)
        try overlay.recoverIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: alpha.path), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gamma.path), run.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.appendingPathComponent("blob.bin").path), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlay.whitelistURL.path), "the overlay must leave no whitelist behind")
        XCTAssertFalse(MoleSummary.lines(run.stdout).isEmpty)
    }
}
