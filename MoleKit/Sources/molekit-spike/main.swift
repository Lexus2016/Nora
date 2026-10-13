import Foundation
import MoleKit

// Spike helpers:
//   molekit-spike overlay-apply <home> <journal> <pattern>...
//       Applies a whitelist overlay, prints "applied", then waits to be killed (crash-recovery test).
//   molekit-spike sudo-check [path-to-mo]
//       Interactive: authenticates with `sudo -A` inside a PTY, then asks Mole's own
//       `adopt_sudo_session` whether it sees that session. Shows a macOS password dialog.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = CommandLine.arguments

switch arguments.dropFirst().first {
case "overlay-apply":
    guard arguments.count >= 5 else { fail("usage: molekit-spike overlay-apply <home> <journal> <pattern>...", code: 64) }
    let overlay = WhitelistOverlay(
        home: URL(fileURLWithPath: arguments[2]),
        journalURL: URL(fileURLWithPath: arguments[3])
    )
    do {
        try overlay.apply(protecting: Array(arguments[4...]), defaults: ["~/spike-default/*"], runID: "spike")
    } catch {
        fail("apply failed: \(error)", code: 1)
    }
    print("applied")
    fflush(stdout)
    while true { sleep(60) }

case "sudo-check":
    let mo = URL(fileURLWithPath: arguments.count >= 3 ? arguments[2] : "/opt/homebrew/bin/mo")
    let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("nora-sudo-check-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: sandbox) }
    do {
        let mole = try MoleInstallation(executable: mo)
        let askpass = sandbox.appendingPathComponent("askpass.sh")
        try PrivilegeBroker.writeDialogAskpass(to: askpass)

        // Same shape as PrivilegeBroker.wrap, but ends in Mole's adopt check instead of a real command.
        let script = """
        sudo -k
        sudo -A -v || { echo NORA_AUTH_FAILED; exit 10; }
        source "$1/lib/core/common.sh" >/dev/null 2>&1
        declare -f adopt_sudo_session >/dev/null || source "$1/lib/core/sudo.sh" >/dev/null 2>&1
        if adopt_sudo_session; then echo NORA_ADOPTED; rc=0; else echo NORA_NOT_ADOPTED; rc=12; fi
        stop_sudo_session >/dev/null 2>&1 || true
        sudo -k
        exit $rc
        """
        let environment = PrivilegeBroker.environment(
            ["HOME": sandbox.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"],
            askpass: askpass
        )
        print("A macOS password dialog will appear. Mole \(try mole.version(environment: environment)), root \(mole.root.path)")
        let session = try PTYSession(
            executable: "/bin/bash", arguments: ["-c", script, "bash", mole.root.path],
            environment: environment, rows: 24, cols: 120
        )
        defer { session.close() }
        let markers = ["NORA_ADOPTED", "NORA_NOT_ADOPTED", "NORA_AUTH_FAILED"]
        try session.waitUntil(timeout: 180, quiet: 0.2, "sudo-check result") { lines in
            lines.contains { markers.contains($0) }
        }
        let status = try session.waitForExit(timeout: 10)
        let lines = session.lines.filter { !$0.isEmpty }
        lines.forEach { print("  | \($0)") }
        let adopted = lines.contains("NORA_ADOPTED")
        print(adopted ? "PASS: Mole adopts the sudo session authenticated in the same PTY (\(status))"
                      : "FAIL: \(status)")
        exit(adopted ? 0 : 1)
    } catch {
        fail("sudo-check failed: \(error)", code: 1)
    }

default:
    fail("usage: molekit-spike overlay-apply <home> <journal> <pattern>... | sudo-check [path-to-mo]", code: 64)
}
