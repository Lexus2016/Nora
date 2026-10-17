import Darwin
import Foundation
import Testing
@testable import MoleKit

/// Every executable here is a shell fixture owned by the test, confined to a fresh temporary
/// HOME. No installed Mole, real cleanup, sudo, or system-setting changes are exercised.
@Suite(.serialized)
struct ManagedProbeRegressionTests {
    private func fixture(_ home: URL, common: String, base: String = "declare -a DEFAULT_WHITELIST_PATTERNS=()\n") throws -> MoleInstallation {
        try TestSandbox.write(base, to: home.appendingPathComponent("lib/core/base.sh"))
        try TestSandbox.write(common, to: home.appendingPathComponent("lib/core/common.sh"))
        try TestSandbox.write("#!/bin/bash\nprintf 'Mole version 1.59.1\\n'\n", to: home.appendingPathComponent("mo"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.appendingPathComponent("mo").path)
        return try MoleInstallation(executable: home.appendingPathComponent("mo"), home: home)
    }

    private var emptyLoader: String { "load_mole_whitelist() { WHITELIST_PATTERNS=(); }\n" }
    private func environment(_ home: URL) -> [String: String] { ["HOME": home.path, "PATH": "/usr/bin:/bin"] }

    private func pid(_ home: URL, _ name: String = "pid") throws -> pid_t {
        let text = try String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
        return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func expectGone(_ pid: pid_t) {
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func exactAndCheckedPathsUseCompleteProtocol() throws {
        let home = try TestSandbox.make("probe-success")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: """
        set -euo pipefail
        load_mole_whitelist() { WHITELIST_PATTERNS=("$HOME/exact"); }
        is_path_whitelisted() { [[ "$1" == "$HOME/glob/"* ]]; }
        """)
        let paths = ["\(home.path)/exact/", "\(home.path)/glob/a", "\(home.path)/open with spaces", "\(home.path)/open\nline"]
        #expect(try installation.unprotected(paths, home: home) == Array(paths.suffix(2)))
        #expect(try installation.unprotected([], home: home).isEmpty)
        #expect(try installation.version(environment: environment(home)) == "1.59.1")
    }

    @Test func legitimateEmptyDefaultsAreDistinctFromMissingDeclaration() throws {
        let home = try TestSandbox.make("probe-defaults")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: emptyLoader)
        #expect(try installation.cleanWhitelistDefaults(home: home).isEmpty)
        try TestSandbox.write(":\n", to: home.appendingPathComponent("lib/core/base.sh"))
        #expect(throws: MoleProbeError.self) { try installation.cleanWhitelistDefaults(home: home) }
    }

    @Test func loaderFailureCannotBecomeAnEmptySuccess() throws {
        let home = try TestSandbox.make("probe-load-failure")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: "load_mole_whitelist() { WHITELIST_PATTERNS=(); return 9; }")
        #expect(throws: MoleProbeError.self) { try installation.unprotected(["\(home.path)/a"], home: home) }
    }

    @Test(arguments: [
        "is_path_whitelisted() { exit 0; }", // successful early exit, no completion
        "is_path_whitelisted() { printf '\\377'; return 1; }", // invalid UTF-8
        "is_path_whitelisted() { printf '%s\\0' \"$HOME/foreign\"; return 0; }",
        "is_path_whitelisted() { printf '%s\\0' \"$1\" \"$1\"; return 0; }",
        "is_path_whitelisted() { return 2; }",
    ])
    func malformedOrIncompleteAnswersFailClosed(function: String) throws {
        let home = try TestSandbox.make("probe-invalid")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: emptyLoader + function)
        #expect(throws: MoleProbeError.self) { try installation.unprotected(["\(home.path)/a"], home: home) }
    }

    @Test func unreadPathsFailEvenWhenAllWritesFitInPipe() throws {
        let home = try TestSandbox.make("probe-unread")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: emptyLoader + "is_path_whitelisted() { exec 0<&-; return 0; }")
        #expect(throws: MoleProbeError.self) {
            try installation.unprotected(["\(home.path)/a", "\(home.path)/b"], home: home)
        }
    }

    @Test func embeddedNULIsRejectedBeforeLaunch() throws {
        let home = try TestSandbox.make("probe-nul")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: "printf started > \"$HOME/started\"\n" + emptyLoader)
        #expect(throws: MoleProbeError.self) { try installation.unprotected(["bad\0path"], home: home) }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("started").path))
    }

    @Test func longRequestAndLongAnswerDoNotDeadlock() throws {
        let home = try TestSandbox.make("probe-two-way")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: emptyLoader + "is_path_whitelisted() { return 1; }")
        let paths = (0..<2500).map { "\(home.path)/\($0)/" + String(repeating: "x", count: 100) }
        #expect(try installation.unprotected(paths, home: home, timeout: 20) == paths)
    }

    @Test func simultaneousFullPipesMakeProgress() throws {
        let home = try TestSandbox.make("probe-full-pipes")
        defer { try? FileManager.default.removeItem(at: home) }
        let input = Data(repeating: 65, count: 512 * 1024)
        let result = try ManagedProbe.run("/bin/sh", ["-c", "/usr/bin/head -c 262144 /dev/zero; /bin/cat"],
                                          environment: environment(home), timeout: 10, initialInput: input)
        #expect(result.succeeded)
        #expect(result.stdout.utf8.count == 262144 + input.count)
        #expect(result.stdout.hasSuffix(String(decoding: input, as: UTF8.self)))
    }

    @Test func stalledHeaderTimesOutAndJoinsTERMResistantChild() throws {
        let home = try TestSandbox.make("probe-stalled")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: """
        load_mole_whitelist() {
            printf '%s' $$ > "$HOME/pid"
            trap '' TERM
            /bin/sleep 10
            printf late > "$HOME/late"
            WHITELIST_PATTERNS=()
        }
        """)
        let cancellation = MoleProbeCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: MoleProbeError.self) {
            try installation.unprotected(["\(home.path)/a"], home: home, timeout: 0.2, cancellation: cancellation)
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 6)
        expectGone(try pid(home))
        #expect(cancellation.canRestoreProtection)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("late").path))
    }

    @Test func blockedWriterIsBoundedAndJoined() throws {
        let home = try TestSandbox.make("probe-blocked-write")
        defer { try? FileManager.default.removeItem(at: home) }
        let cancellation = MoleProbeCancellation()
        #expect(throws: MoleProbeError.self) {
            try ManagedProbe.run("/bin/sh", ["-c", "printf '%s' $$ > \"$HOME/pid\"; trap '' TERM; /bin/sleep 10"],
                                 environment: environment(home), timeout: 0.2, cancellation: cancellation,
                                 initialInput: Data(repeating: 65, count: 2 * 1024 * 1024))
        }
        expectGone(try pid(home))
        #expect(cancellation.canRestoreProtection)
    }

    @Test func closedInputReturnsWriteFailureWithoutSIGPIPE() throws {
        let home = try TestSandbox.make("probe-closed-input")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: MoleProbeError.self) {
            try ManagedProbe.run("/bin/sh", ["-c", "exec 0<&-; printf ready; /bin/sleep 1"],
                                 environment: environment(home), timeout: 5,
                                 initialInput: Data(repeating: 65, count: 2 * 1024 * 1024))
        }
    }

    @Test func childHoldingOutputAfterLeaderExitIsSettled() throws {
        let home = try TestSandbox.make("probe-grandchild")
        defer { try? FileManager.default.removeItem(at: home) }
        let cancellation = MoleProbeCancellation()
        #expect(throws: MoleProbeError.self) {
            try ManagedProbe.run("/bin/sh", ["-c", """
                printf '%s' $$ > "$HOME/pid"
                /bin/sh -c 'trap "" TERM; /bin/sleep 10; printf late > "$HOME/late"' &
                printf '%s' $! > "$HOME/helper"
                exit 0
                """], environment: environment(home), timeout: 0.2, cancellation: cancellation)
        }
        expectGone(try pid(home))
        expectGone(try pid(home, "helper"))
        #expect(cancellation.canRestoreProtection)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("late").path))
    }

    @Test func preCancelledProbeNeverLaunches() throws {
        let home = try TestSandbox.make("probe-pre-cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let cancellation = MoleProbeCancellation()
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try ManagedProbe.run("/bin/sh", ["-c", "printf started > \"$HOME/started\""],
                                 environment: environment(home), cancellation: cancellation)
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("started").path))
        #expect(cancellation.canRestoreProtection)
    }

    @Test func cancellationDuringLoadJoinsBeforeOverlayRecovery() async throws {
        let home = try TestSandbox.make("probe-cancel-overlay")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: """
        load_mole_whitelist() {
            printf '%s' $$ > "$HOME/pid"
            trap '' TERM
            /bin/sleep 10
            printf late > "$HOME/late"
            WHITELIST_PATTERNS=()
        }
        """)
        let overlay = WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("journal.json"))
        try TestSandbox.write("~/original\n", to: overlay.whitelistURL)
        try overlay.apply(protecting: ["\(home.path)/a"], defaults: [], runID: "cancel")
        let cancellation = MoleProbeCancellation()
        let task = Task.detached {
            try installation.unprotected(["\(home.path)/a"], home: home, timeout: 10, cancellation: cancellation)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: home.appendingPathComponent("pid").path),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        cancellation.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        expectGone(try pid(home))
        #expect(cancellation.canRestoreProtection)
        try overlay.recover(runID: "cancel")
        #expect(try String(contentsOf: overlay.whitelistURL, encoding: .utf8) == "~/original\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("late").path))
    }

    @Test func inconclusiveMembershipRetainsRecoveryHoldUntilObservedSettled() async throws {
        let home = try TestSandbox.make("probe-unsettled")
        defer { try? FileManager.default.removeItem(at: home) }
        let allowSettlement = Flag()
        let cancellation = MoleProbeCancellation()
        let settlement = ProbeSettlement(grace: 0.02, hardGrace: 0.02, otherMembers: { _ in allowSettlement.isSet ? 0 : -1 })
        defer { allowSettlement.set() }
        do {
            _ = try ManagedProbe.run("/bin/sh", ["-c", "printf '%s' $$ > \"$HOME/pid\""],
                                     environment: environment(home), cancellation: cancellation, settlement: settlement)
            Issue.record("Expected unsettled helper")
        } catch { #expect(error as? MoleProbeError != nil) }
        #expect(!cancellation.canRestoreProtection)
        let leader = try pid(home)
        #expect(kill(leader, 0) == 0, "Unreaped leader pins ownership while inspection is inconclusive")
        allowSettlement.set()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !cancellation.canRestoreProtection, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cancellation.canRestoreProtection)
        expectGone(leader)
    }

    @Test func outputFloodCannotStarveBlockedInputTimeout() throws {
        let home = try TestSandbox.make("probe-flood")
        defer { try? FileManager.default.removeItem(at: home) }
        let cancellation = MoleProbeCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: MoleProbeError.self) {
            try ManagedProbe.run("/bin/sh", ["-c", "printf '%s' $$ > \"$HOME/pid\"; while :; do printf '012345678901234567890123456789\\n'; done"],
                                 environment: environment(home), timeout: 0.2, cancellation: cancellation,
                                 initialInput: Data(repeating: 65, count: 2 * 1024 * 1024))
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 6)
        #expect(cancellation.canRestoreProtection)
        expectGone(try pid(home))
    }

    @Test func repeatedSuccessAndFailedSpawnDoNotLeakDescriptorsOrOwners() throws {
        let home = try TestSandbox.make("probe-repeat")
        defer { try? FileManager.default.removeItem(at: home) }
        let owners = ChildProcesses.activeProbeCount
        let descriptors = (0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
        for _ in 0..<20 {
            let result = try ManagedProbe.run("/bin/sh", ["-c", "printf ok"], environment: environment(home))
            #expect(result.succeeded && result.stdout == "ok")
        }
        #expect(throws: MoleProbeError.self) {
            try ManagedProbe.run(home.appendingPathComponent("missing-executable").path, [], environment: environment(home))
        }
        #expect(ChildProcesses.activeProbeCount == owners)
        #expect((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count <= descriptors + 2)
    }

    @Test func asyncProbeBridgesParentTaskCancellation() async throws {
        let home = try TestSandbox.make("probe-async-cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = environment(home)
        let owners = ChildProcesses.activeProbeCount
        let task = Task {
            try await ProcessRunner.probe(URL(fileURLWithPath: "/bin/sh"),
                ["-c", "printf '%s' $$ > \"$HOME/pid\"; trap '' TERM; /bin/sleep 10"],
                environment: environment, timeout: 10)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: home.appendingPathComponent("pid").path),
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected parent cancellation") }
        catch { #expect(error is CancellationError) }
        expectGone(try pid(home))
        #expect(ChildProcesses.activeProbeCount == owners)
    }


    @Test func failedCommandPreservesSeparatedDiagnostics() throws {
        let home = try TestSandbox.make("probe-stderr-status")
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try ManagedProbe.run("/bin/sh", ["-c", "printf status; printf 'permission denied\\n' >&2; exit 7"],
                                          environment: environment(home))
        #expect(result.status == 7)
        #expect(result.stdout == "status")
        #expect(result.stderr == "permission denied\n")
    }

    @Test func stderrCannotCorruptProtectionFraming() throws {
        let home = try TestSandbox.make("probe-stderr-protocol")
        defer { try? FileManager.default.removeItem(at: home) }
        let installation = try fixture(home, common: emptyLoader + "is_path_whitelisted() { printf '\\377\\0diagnostic\\0' >&2; return 1; }")
        let path = home.appendingPathComponent("unprotected").path
        #expect(try installation.unprotected([path], home: home) == [path])
    }

    @Test func simultaneousFullStderrAndInputMakeProgress() throws {
        let home = try TestSandbox.make("probe-full-stderr")
        defer { try? FileManager.default.removeItem(at: home) }
        let input = Data(repeating: 65, count: 512 * 1024)
        let result = try ManagedProbe.run("/bin/sh", ["-c", "/usr/bin/head -c 262144 /dev/zero >&2; printf result; /bin/cat"],
                                          environment: environment(home), timeout: 10, initialInput: input)
        #expect(result.succeeded)
        #expect(result.stderr.utf8.count == 262144)
        #expect(result.stdout == "result" + String(decoding: input, as: UTF8.self))
    }

    @Test func stderrFloodCannotStarveTimeoutOrInput() throws {
        let home = try TestSandbox.make("probe-stderr-flood")
        defer { try? FileManager.default.removeItem(at: home) }
        let cancellation = MoleProbeCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: MoleProbeError.self) {
            try ManagedProbe.run("/bin/sh", ["-c", "printf '%s' $$ > \"$HOME/pid\"; while :; do printf 'diagnostic flood 0123456789\\n' >&2; done"],
                                 environment: environment(home), timeout: 0.2, cancellation: cancellation,
                                 initialInput: Data(repeating: 65, count: 2 * 1024 * 1024))
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 6)
        #expect(cancellation.canRestoreProtection)
        expectGone(try pid(home))
    }

    @Test func malformedDiagnosticUTF8IsVisiblyReplaced() throws {
        let home = try TestSandbox.make("probe-stderr-encoding")
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try ManagedProbe.run("/bin/sh", ["-c", "printf ok; printf '\\377bad\\n' >&2"],
                                          environment: environment(home))
        #expect(result.succeeded && result.stdout == "ok")
        #expect(result.stderr.hasPrefix("[Non-UTF-8 diagnostic bytes were replaced.]\n"))
        #expect(result.stderr.contains("\u{FFFD}bad"))
    }

}
