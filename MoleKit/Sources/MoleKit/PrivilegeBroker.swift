import Foundation

/// Runs a Mole command with administrator rights authenticated inside the same PTY.
///
/// sudo caches credentials per tty session, and Mole's `adopt_sudo_session` checks them
/// with `sudo -n -v`, so authenticating in a separate process would not be seen.
/// `sudo -A` asks the `SUDO_ASKPASS` helper; Nora never sees or stores the password.
public enum PrivilegeBroker {
    /// `bash -c 'sudo -A -v || exit 1; exec mo …'`: Mole never starts if authentication fails.
    public static func wrap(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        ("/bin/bash", ["-c", "sudo -A -v || exit 1; exec \"$0\" \"$@\"", executable] + arguments)
    }

    /// The line `gated` prints between its two commands, with the first one's exit status.
    public static let gateMarker = "__NORA_CHECKED__"

    /// Two Mole commands under one authentication in one PTY: `check` runs, the gate line goes
    /// out, then `run` starts only when the caller writes `go` and a newline. Anything else, or
    /// the session closing, ends it before `run`. Used where a read-only check must see exactly
    /// what the privileged run will see, because sudo's credentials do not carry to another tty.
    /// `authenticate: false` leaves out the sudo step, for tests.
    public static func gated(executable: String, check: [String], run: [String], authenticate: Bool = true) -> (executable: String, arguments: [String]) {
        let quote = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = (authenticate ? "sudo -A -v || exit 1; " : "") + "\"$0\" \(check.map(quote).joined(separator: " ")); "
            + "printf '\\n%s %d\\n' \(gateMarker) $?; IFS= read -r go; [ \"$go\" = go ] || exit 3; "
            + "exec \"$0\" \(run.map(quote).joined(separator: " "))"
        return ("/bin/bash", ["-c", script, executable])
    }

    public static func environment(_ base: [String: String], askpass: URL) -> [String: String] {
        base.merging(["SUDO_ASKPASS": askpass.path]) { _, new in new }
    }

    /// Spike askpass: a native password dialog through osascript, printed to stdout for sudo.
    /// The shipping app replaces it with a signed helper that can use Touch ID.
    public static func writeDialogAskpass(
        to url: URL,
        message: String = "Nora needs administrator access for this Mole command.",
        cancel: String = "Cancel",
        ok: String = "OK"
    ) throws {
        func quoted(_ s: String) -> String {
            // AppleScript string inside a single-quoted shell word.
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "'", with: "\u{2019}") + "\""
        }
        let script = """
        #!/bin/sh
        exec /usr/bin/osascript \
          -e 'set answer to display dialog \(quoted(message)) default answer "" with hidden answer with title "Nora" with icon caution buttons {\(quoted(cancel)), \(quoted(ok))} default button \(quoted(ok))' \
          -e 'text returned of answer'

        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
