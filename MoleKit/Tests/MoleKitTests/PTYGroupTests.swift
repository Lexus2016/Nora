import Foundation
import Testing
@testable import MoleKit

struct PTYGroupTests {
    /// A leader that exits at once can leave a helper running in its group. The group counts as
    /// alive until the helper is gone, and terminate() stops the helper too.
    @Test func terminateStopsHelpersLeftByAnExitedLeader() throws {
        // The trap is set before the fork, so the helper starts with HUP ignored. Set inside the
        // subshell it raced the hangup that follows the leader's exit and sometimes lost.
        let session = try PTYSession(executable: "/bin/sh", arguments: ["-c", "trap '' HUP; sleep 30 & exit 0"],
                                     environment: ["PATH": "/bin:/usr/bin"])
        _ = try session.waitForExit(timeout: 5)
        usleep(200_000)
        #expect(ChildProcesses.groupAlive(session.pid), "the helper keeps the group alive after the leader exits")
        session.terminate(grace: 2)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, ChildProcesses.groupAlive(session.pid) { usleep(50_000) }
        #expect(!ChildProcesses.groupAlive(session.pid))
    }
}

/// `PrivilegeBroker.gated`: the second command starts only after the caller says `go`.
struct GatedRunTests {
    private func script(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gated-\(UUID().uuidString)")
        try Data("#!/bin/sh\necho \"ran $*\" >> \"\(name)\"\n[ \"$1\" = fail ] && exit 2\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test(arguments: [true, false]) func runStartsOnlyAfterGo(go: Bool) async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("gated-log-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let exe = try script(log)
        let (bash, args) = PrivilegeBroker.gated(executable: exe.path, check: ["check", "it's"], run: ["run"], authenticate: false)
        let outcome = try await PTYRun.drive(wrapped: bash, arguments: args, environment: ["PATH": "/usr/bin:/bin"], exitTimeout: 10) { session in
            let screen = try session.waitUntil(timeout: 10, "gate") { $0.contains { $0.hasPrefix(PrivilegeBroker.gateMarker) } }
            #expect(screen.contains("\(PrivilegeBroker.gateMarker) 0"))
            #expect(((try? String(contentsOfFile: log, encoding: .utf8)) ?? "") == "ran check it's\n", "the run has not started")
            session.write(go ? "go\n" : "no\n")
        }
        let ran = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(ran == (go ? "ran check it's\nran run\n" : "ran check it's\n"))
        #expect(outcome.result.status == .exited(go ? 0 : 3))
    }

    @Test func gateReportsTheCheckStatus() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("gated-log-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: log) }
        let (bash, args) = PrivilegeBroker.gated(executable: try script(log).path, check: ["fail"], run: ["run"], authenticate: false)
        _ = try await PTYRun.drive(wrapped: bash, arguments: args, environment: ["PATH": "/usr/bin:/bin"], exitTimeout: 10) { session in
            try session.waitUntil(timeout: 10, "gate") { $0.contains("\(PrivilegeBroker.gateMarker) 2") }
            session.write("no\n")
        }
    }
}

/// D04: a pipe child's helper that ignores SIGTERM is gone by the time a stopped run returns.
struct PipeGroupTests {
    @Test func stoppedRunReturnsOnlyAfterItsHelpersAreGone() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-helper-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let script = "(trap '' TERM; sleep 60) >/dev/null 2>&1 & echo $! > '\(pidFile)'; wait"
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], environment: ["PATH": "/usr/bin:/bin"]) }
        var helper: pid_t = 0
        for _ in 0..<50 where helper == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
            helper = pid_t((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        #expect(helper > 0)
        #expect(kill(helper, 0) == 0, "the helper runs")
        task.cancel()
        _ = try? await task.value
        #expect(kill(helper, 0) != 0, "the helper is gone when the stopped run returns")
    }
}

/// The gated sudo session against the real `mo`, read-only: `mo clean --dry-run` both as the
/// check and as the "run". Asks for the Mac password once, so it runs only with
/// `NORA_MOLE_SUDO=1`; never under `NORA_MOLE_E2E` (which promises no sudo) or the release gate.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NORA_MOLE_SUDO"] == "1" && MoleE2E.executable != nil))
struct GatedSudoLiveTests {
    @Test func dryRunCheckThenDryRunUnderOneAuthentication() async throws {
        let mo = try #require(MoleE2E.executable)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let askpass = FileManager.default.temporaryDirectory.appendingPathComponent("nora-askpass-\(UUID().uuidString)")
        let prompts = askpass.path + ".count"
        defer { try? FileManager.default.removeItem(at: askpass); try? FileManager.default.removeItem(atPath: prompts) }
        try PrivilegeBroker.writeDialogAskpass(to: askpass, message: "Nora test: one password for a read-only dry run.")
        // Count how often sudo asks: a second prompt would mean the ticket did not carry over.
        let script = try String(contentsOf: askpass, encoding: .utf8)
            .replacingOccurrences(of: "exec /usr/bin/osascript", with: "echo x >> '\(prompts)'; exec /usr/bin/osascript")
        try Data(script.utf8).write(to: askpass)

        let list = home.appendingPathComponent(".config/mole/clean-list.txt")
        let started = Date()
        let (bash, args) = PrivilegeBroker.gated(executable: mo.path, check: ["clean", "--dry-run"], run: ["clean", "--dry-run"])
        var env = ProcessInfo.processInfo.environment
        env["SUDO_ASKPASS"] = askpass.path
        // What Nora reads at the gate: the check's output and the list as it is at that moment.
        let outcome = try await PTYRun.drive(wrapped: bash, arguments: args, environment: env, exitTimeout: 1800) { session in
            let marker = PrivilegeBroker.gateMarker + " "
            let screen = try session.waitUntil(timeout: 1800, "the check") { $0.contains { $0.hasPrefix(marker) } }
            let output = TerminalText.render(session.transcriptBytes)
            let check = String(output[..<(output.range(of: PrivilegeBroker.gateMarker)?.lowerBound ?? output.endIndex)])
            let modified = (try? FileManager.default.attributesOfItem(atPath: list.path)[.modificationDate]) as? Date
            let text = try? String(contentsOf: list, encoding: .utf8)
            session.write("go\n")
            return (screen.last { $0.hasPrefix(marker) } ?? "", check, modified, text)
        }
        let (gate, check, modified, text) = outcome.value
        #expect(gate == PrivilegeBroker.gateMarker + " 0", "\(gate)")
        #expect(check.contains("Dry run complete"), "\(check.suffix(2000))")
        if check.contains("Detailed file list:") {
            #expect((modified ?? .distantPast) >= started.addingTimeInterval(-2), "clean-list.txt was fresh at the gate: \(String(describing: modified))")
            #expect(!CleanPreview.parse(cleanList: text ?? "", stdout: check).items.isEmpty)
        }
        #expect(!check.localizedCaseInsensitiveContains("need sudo"), "the check ran with administrator rights")
        let run = String(outcome.result.text[(outcome.result.text.range(of: PrivilegeBroker.gateMarker)?.upperBound ?? outcome.result.text.startIndex)...])
        #expect(!run.localizedCaseInsensitiveContains("need sudo"), "the second command kept them")
        #expect(outcome.result.status == .exited(0))
        let asked = (try? String(contentsOfFile: prompts, encoding: .utf8))?.split(separator: "\n").count ?? 0
        #expect(asked == 1, "one password prompt, not \(asked)")
    }
}
