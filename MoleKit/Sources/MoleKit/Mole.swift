import Foundation

/// A located, version-checked Mole that Nora can run commands against.
public struct Mole: Sendable {
    /// Oldest Mole whose output formats the parsers are tested against.
    public static let minimumVersion = "1.55.0"

    public let installation: MoleInstallation
    public let version: String
    public let home: URL

    public init(installation: MoleInstallation, version: String, home: URL) {
        self.installation = installation
        self.version = version
        self.home = home
    }

    public var executable: URL { installation.executable }
    public var isSupported: Bool { Self.compare(version, Self.minimumVersion) != .orderedAscending }

    /// Install channel, used for updates: Homebrew updates through `brew upgrade mole`.
    public var isHomebrew: Bool {
        installation.root.path.contains("/Cellar/") || installation.root.path.hasPrefix("/opt/homebrew/")
            || installation.root.path.hasPrefix("/usr/local/opt/")
    }

    /// The environment every Mole command gets. A Finder or launchd launch has no Homebrew in
    /// `PATH`, and the parsers expect English output, so both are set explicitly.
    public var environment: [String: String] { Self.environment(home: home, extraPath: executable.deletingLastPathComponent().path) }

    public static func environment(home: URL, extraPath: String? = nil) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var path = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let extraPath, !path.contains(extraPath) { path.insert(extraPath, at: 0) }
        var env: [String: String] = [
            "HOME": home.path,
            "PATH": path.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "xterm-256color",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SHELL"] { env[key] = inherited[key] }
        return env
    }

    public func command(_ arguments: [String], environment extra: [String: String] = [:]) -> ShellCommand {
        ShellCommand(executable.path, arguments, environment: extra)
    }

    public func run(_ arguments: [String], environment extra: [String: String] = [:]) async throws -> CommandResult {
        try await ProcessRunner.run(executable, arguments, environment: environment.merging(extra) { $1 })
    }

    /// Compares dotted versions numerically ("1.59.1" > "1.9").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// Finds `mo` the way a Finder-launched app has to: fixed install locations first, then the
/// user's login shell, which also covers Nix and custom prefixes.
public enum MoleLocator {
    public static func candidates(home: URL) -> [URL] {
        [
            "/opt/homebrew/bin/mo",
            "/usr/local/bin/mo",
            home.appendingPathComponent(".local/bin/mo").path,
            home.appendingPathComponent(".mole/bin/mo").path,
            home.appendingPathComponent(".nix-profile/bin/mo").path,
            "/run/current-system/sw/bin/mo",
        ].map { URL(fileURLWithPath: $0) }
    }

    public enum Outcome: Sendable {
        case found(Mole)
        case missing
        case broken(path: String, reason: String)
    }

    public static func locate(home: URL, override: URL? = nil) async -> Outcome {
        var paths = (override.map { [$0] } ?? []) + candidates(home: home)
        if let fromShell = await loginShellPath(home: home) { paths.append(fromShell) }
        var lastProblem: (String, String)?
        for url in paths where FileManager.default.isExecutableFile(atPath: url.path) {
            do {
                let installation = try MoleInstallation(executable: url, home: home)
                let version = try installation.version(environment: Mole.environment(home: home, extraPath: url.deletingLastPathComponent().path))
                return .found(Mole(installation: installation, version: version, home: home))
            } catch {
                lastProblem = (url.path, String(describing: error))
            }
        }
        if let lastProblem { return .broken(path: lastProblem.0, reason: lastProblem.1) }
        return .missing
    }

    static func loginShellPath(home: URL) async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard let result = try? await withTimeout(seconds: 5, {
            try await ProcessRunner.run(URL(fileURLWithPath: shell), ["-lc", "command -v mo"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        }), result.succeeded else { return nil }
        let path = result.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}
