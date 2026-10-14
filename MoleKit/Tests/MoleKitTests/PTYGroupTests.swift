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
