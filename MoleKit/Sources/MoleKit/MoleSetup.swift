import Foundation

/// Installs and updates Mole without asking for a password: Homebrew when it is present,
/// otherwise Mole's official install script into `~/.local/bin`.
public enum MoleSetup {
    public enum Channel: Sendable, Equatable {
        case homebrew(brew: URL)
        case script
    }

    public static func homebrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func preferredChannel() -> Channel {
        homebrew().map { .homebrew(brew: $0) } ?? .script
    }

    /// The commands an install runs, shown to the user before running them.
    public static func installCommands(_ channel: Channel, home: URL) -> [ShellCommand] {
        switch channel {
        case .homebrew(let brew):
            return [ShellCommand(brew.path, ["install", "mole"])]
        case .script:
            let script = home.appendingPathComponent("Library/Caches/Nora/mole-install.sh").path
            return [
                ShellCommand("/usr/bin/curl", ["-fsSL", "-o", script, installScriptURL.absoluteString]),
                ShellCommand("/bin/bash", [script, "--prefix", home.appendingPathComponent(".local/bin").path]),
            ]
        }
    }

    public static let installScriptURL = URL(string: "https://raw.githubusercontent.com/tw93/mole/main/install.sh")!

    /// Updates through the channel Mole was installed with.
    public static func updateCommand(for mole: Mole) -> ShellCommand {
        if mole.isHomebrew, let brew = homebrew() {
            return ShellCommand(brew.path, ["upgrade", "mole"])
        }
        return ShellCommand(mole.executable.path, ["update"])
    }

    /// The latest released Mole version from GitHub, e.g. "1.59.1".
    public static func latestVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/tw93/Mole/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Release: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        return tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }
}
