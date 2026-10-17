import Darwin
import Foundation
import MoleKit
import XCTest
@testable import Nora

@MainActor
final class ProtectionProbeSafetyTests: XCTestCase {
    func testCancelledProtectionJoinsDetachedProbeBeforeRecovery() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nora-app-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("lib/core"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "declare -a DEFAULT_WHITELIST_PATTERNS=()\n".write(to: home.appendingPathComponent("lib/core/base.sh"), atomically: true, encoding: .utf8)
        try """
        load_mole_whitelist() {
            printf '%s' $$ > "$HOME/probe-pid"
            trap '' TERM
            /bin/sleep 10
            printf late > "$HOME/late"
            WHITELIST_PATTERNS=()
        }
        """.write(to: home.appendingPathComponent("lib/core/common.sh"), atomically: true, encoding: .utf8)
        let installation = try MoleInstallation(executable: home.appendingPathComponent("mo"), home: home)
        let mole = Mole(installation: installation, version: "1.59.1", home: home)
        let app = AppModel(home: home)
        let runID = "fixture"
        XCTAssertTrue(app.beginExclusiveRun(runID))
        let task = Task { try await app.protect([home.appendingPathComponent("keep").path], with: mole, runID: runID) }
        let ready = home.appendingPathComponent("probe-pid")
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: ready.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: ready, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(app.overlay.needsRecovery)
        try app.recoverProtection(runID: runID)
        app.endExclusiveRun(runID)
        XCTAssertFalse(app.overlay.needsRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("late").path))
    }

    func testCancellationBeforeProtectionLeavesNoOverlay() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nora-app-pre-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("lib/core"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent("lib/core/base.sh"))
        let installation = try MoleInstallation(executable: home.appendingPathComponent("mo"), home: home)
        let overlay = WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("journal.json"))
        let cancellation = MoleProbeCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try AppModel.protect([home.appendingPathComponent("keep").path], overlay: overlay,
                                                 installation: installation, home: home, runID: "fixture", cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(overlay.needsRecovery)
    }
}
