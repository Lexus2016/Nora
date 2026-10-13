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

    public static func environment(_ base: [String: String], askpass: URL) -> [String: String] {
        base.merging(["SUDO_ASKPASS": askpass.path]) { _, new in new }
    }

    /// Spike askpass: a native password dialog through osascript, printed to stdout for sudo.
    /// The shipping app replaces it with a signed helper that can use Touch ID.
    public static func writeDialogAskpass(to url: URL) throws {
        let script = """
        #!/bin/sh
        exec /usr/bin/osascript \
          -e 'set answer to display dialog "Nora needs administrator access for this Mole command." default answer "" with hidden answer with title "Nora" with icon caution buttons {"Cancel", "OK"} default button "OK"' \
          -e 'text returned of answer'

        """
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
