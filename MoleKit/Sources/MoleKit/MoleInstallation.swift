import Foundation

/// An installed Mole: the `mo` launcher and the directory holding its `lib/`.
public struct MoleInstallation: Sendable {
    public let executable: URL
    public let root: URL

    public init(executable: URL) throws {
        self.executable = executable
        // Homebrew and install.sh both symlink `mo` to `<root>/mole` or `<root>/bin/mo`.
        let resolved = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [resolved, resolved.deletingLastPathComponent()]
        guard let root = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("lib/core/base.sh").path)
        }) else {
            throw PTYError(description: "no lib/core/base.sh next to \(executable.path)")
        }
        self.root = root
    }

    /// `mo --version` → "1.59.1".
    public func version(environment: [String: String]) throws -> String {
        let output = try Self.run(executable.path, ["--version"], environment: environment)
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Mole version ") }) else {
            throw PTYError(description: "unexpected `mo --version` output: \(output)")
        }
        return String(line.dropFirst("Mole version ".count))
    }

    /// Mole's optional clean-whitelist defaults, expanded for `home`, read from the
    /// installed version rather than copied, so they never drift from what Mole would apply.
    public func cleanWhitelistDefaults(home: URL) throws -> [String] {
        let script = """
        source "$1/lib/core/base.sh" >/dev/null 2>&1 || exit 3
        printf '%s\\n' "${DEFAULT_WHITELIST_PATTERNS[@]}"
        """
        let output = try Self.run("/bin/bash", ["-c", script, "bash", root.path], environment: Self.probeEnvironment(home))
        return output.split(separator: "\n").map(String.init)
    }

    /// Maintenance tasks `mo optimize` can skip, as Mole lists them for its own whitelist editor
    /// (`get_optimize_whitelist_items`): display name and the id written to `whitelist_optimize`.
    public func optimizeTasks(home: URL) throws -> [(name: String, id: String)] {
        let script = """
        source "$1/lib/core/common.sh" >/dev/null 2>&1 || exit 3
        source "$1/lib/manage/whitelist.sh" >/dev/null 2>&1 || exit 3
        source "$1/lib/optimize/catalog.sh" >/dev/null 2>&1 || exit 3
        get_optimize_whitelist_items
        """
        let output = try Self.run("/bin/bash", ["-c", script, "bash", root.path], environment: Self.probeEnvironment(home))
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// Asks the check Mole's deletion sink uses (`is_path_whitelisted`) whether `path`
    /// is protected for `home`. `is_whitelisted` in whitelist.sh only compares pattern strings.
    public func protects(_ path: String, home: URL) throws -> Bool {
        let script = """
        source "$1/lib/core/common.sh" >/dev/null 2>&1 || exit 3
        load_mole_whitelist >/dev/null 2>&1
        is_path_whitelisted "$2" && echo yes || echo no
        """
        let output = try Self.run("/bin/bash", ["-c", script, "bash", root.path, path], environment: Self.probeEnvironment(home))
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    static func probeEnvironment(_ home: URL) -> [String: String] {
        ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PTYError(description: "\(executable) \(arguments.prefix(2)) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
