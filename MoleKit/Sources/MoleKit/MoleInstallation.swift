import Foundation

/// An installed Mole: the `mo` launcher and the directory holding its `lib/`.
public struct MoleInstallation: Sendable {
    public let executable: URL
    public let root: URL

    public init(executable: URL, home: URL? = nil) throws {
        self.executable = executable
        // Homebrew keeps lib/ next to `mole` or one level up. Mole's install.sh copies `mo` and `mole`
        // into the prefix, puts lib/ in ~/.config/mole and pins that folder in the launcher.
        let resolvedFile = executable.resolvingSymlinksInPath()
        let resolved = resolvedFile.deletingLastPathComponent()
        var candidates = [resolved, resolved.deletingLastPathComponent()]
        for launcher in [resolvedFile, resolved.appendingPathComponent("mole")] {
            if let pinned = Self.pinnedScriptDir(launcher) { candidates.append(pinned) }
        }
        if let home { candidates.append(home.appendingPathComponent(".config/mole", isDirectory: true)) }
        guard let root = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("lib/core/base.sh").path)
        }) else {
            throw PTYError(description: "no lib/core/base.sh next to \(executable.path)")
        }
        self.root = root
    }

    /// The `SCRIPT_DIR=/path` line install.sh writes into the launcher (escaped with printf %q).
    /// Nil for the stock `SCRIPT_DIR="$(dirname …)"` line or anything that is not a plain path.
    static func pinnedScriptDir(_ launcher: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: launcher) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("SCRIPT_DIR=") {
            let value = line.dropFirst("SCRIPT_DIR=".count)
            guard value.hasPrefix("/") else { continue }
            var path = "", escaped = false
            for character in value {
                if escaped { path.append(character); escaped = false } else if character == "\\" { escaped = true } else { path.append(character) }
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// `mo --version` → "1.59.1".
    public func version(environment: [String: String], timeout: TimeInterval = 15,
                        cancellation: MoleProbeCancellation = MoleProbeCancellation()) throws -> String {
        let output = try Self.run(executable.path, ["--version"], environment: environment,
                                  timeout: timeout, cancellation: cancellation)
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Mole version ") }) else {
            throw PTYError(description: "unexpected `mo --version` output: \(output)")
        }
        return String(line.dropFirst("Mole version ".count))
    }

    /// Mole's optional clean-whitelist defaults, expanded for `home`, read from the
    /// installed version rather than copied, so they never drift from what Mole would apply.
    public func cleanWhitelistDefaults(home: URL, timeout: TimeInterval = 120,
                                       cancellation: MoleProbeCancellation = MoleProbeCancellation()) throws -> [String] {
        let script = """
        source "$1/lib/core/base.sh" >/dev/null 2>&1 || exit 3
        declare -p DEFAULT_WHITELIST_PATTERNS >/dev/null 2>&1 || exit 4
        [ ${#DEFAULT_WHITELIST_PATTERNS[@]} -eq 0 ] || printf '%s\\0' "${DEFAULT_WHITELIST_PATTERNS[@]}"
        printf '\\0'
        """
        let output = try Self.run("/bin/bash", ["-c", script, "bash", root.path], environment: Self.probeEnvironment(home),
                                  timeout: timeout, cancellation: cancellation)
        return try Self.completeRecords(Data(output.utf8))
    }

    /// Maintenance tasks `mo optimize` can skip, as Mole lists them for its own whitelist editor
    /// (`get_optimize_whitelist_items`): display name and the id written to `whitelist_optimize`.
    public func optimizeTasks(home: URL, timeout: TimeInterval = 120,
                              cancellation: MoleProbeCancellation = MoleProbeCancellation()) throws -> [(name: String, id: String)] {
        let script = """
        source "$1/lib/core/common.sh" >/dev/null 2>&1 || exit 3
        source "$1/lib/manage/whitelist.sh" >/dev/null 2>&1 || exit 3
        source "$1/lib/optimize/catalog.sh" >/dev/null 2>&1 || exit 3
        items=$(get_optimize_whitelist_items) || exit 4
        [ -z "$items" ] || printf '%s\\0' "$items"
        printf '\\0'
        """
        let output = try Self.run("/bin/bash", ["-c", script, "bash", root.path], environment: Self.probeEnvironment(home),
                                  timeout: timeout, cancellation: cancellation)
        return try Self.completeRecords(Data(output.utf8)).flatMap { $0.split(separator: "\n") }.map { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw MoleProbeError.invalidResponse("invalid maintenance task")
            }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// Asks the check Mole's deletion sink uses (`is_path_whitelisted`) whether `path`
    /// is protected for `home`. `is_whitelisted` in whitelist.sh only compares pattern strings.
    public func protects(_ path: String, home: URL) throws -> Bool {
        try unprotected([path], home: home).isEmpty
    }

    /// The paths Mole would not protect for `home` under its current whitelist. Mole's loader drops
    /// or trims some literal paths (a name with `..` in it, a trailing space), so a written rule is
    /// not proof; this is.
    ///
    /// Mole's loader is quadratic in the number of rules (1,500 take about 24 s) and so is a loop
    /// over `is_path_whitelisted`, so one shell loads the whitelist once and prints the loaded
    /// patterns. A path equal to one of them, normalized as Mole does, is protected by
    /// `is_path_whitelisted`'s exact-match branch; only the rest are sent back to the same shell
    /// for the full check. NUL-separated UTF-8 preserves spaces and newlines in names;
    /// malformed encoding, embedded NUL, incomplete records and unread paths fail closed.
    public func unprotected(_ paths: [String], home: URL, timeout: TimeInterval = 120,
                            cancellation: MoleProbeCancellation = MoleProbeCancellation()) throws -> [String] {
        try cancellation.checkCancellation()
        guard !paths.isEmpty else { return [] }
        guard paths.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else {
            throw MoleProbeError.invalidResponse("an input path was empty or contained NUL")
        }
        let script = """
        source "$1/lib/core/common.sh" >/dev/null 2>&1 || exit 3
        load_mole_whitelist >/dev/null 2>&1 || exit 4
        declare -p WHITELIST_PATTERNS >/dev/null 2>&1 || exit 4
        [ ${#WHITELIST_PATTERNS[@]} -eq 0 ] || printf '%s\\0' "${WHITELIST_PATTERNS[@]}"
        printf '\\0'
        processed=0
        while IFS= read -r -d '' p; do
            if is_path_whitelisted "$p"; then
                :
            else
                [ "$?" -eq 1 ] || exit 5
                printf '%s\\0' "$p"
            fi
            processed=$((processed + 1))
        done
        printf 'NORA_PROBE_COMPLETE:%s\\0\\0' "$processed"
        """
        var headerLength: Int?
        var rest: [String] = []
        var expectedCount = 0
        let result = try ManagedProbe.run("/bin/bash", ["-c", script, "bash", root.path],
                                         environment: Self.probeEnvironment(home), timeout: timeout,
                                         cancellation: cancellation, initialInput: nil) { data in
            guard let frame = try Self.recordPrefix(data) else { return nil }
            headerLength = frame.length
            let exact = Set(frame.records.map(Self.normalized))
            rest = paths.filter { !exact.contains(Self.normalized($0)) }
            var sent: Set<String> = []
            let unique = rest.filter { sent.insert($0).inserted }
            expectedCount = unique.count
            return Data(unique.map { $0 + "\0" }.joined().utf8)
        }
        guard result.succeeded else { throw MoleProbeError.io("helper exited with status \(result.status)") }
        let data = Data(result.stdout.utf8)
        guard let headerLength else { throw MoleProbeError.invalidResponse("missing pattern-list completion") }
        var records = try Self.completeRecords(Data(data.dropFirst(headerLength)))
        guard records.last == "NORA_PROBE_COMPLETE:\(expectedCount)" else {
            throw MoleProbeError.invalidResponse("missing completion count or unread input paths")
        }
        records.removeLast()
        let open = Set(records)
        guard open.count == records.count, open.isSubset(of: Set(rest)) else {
            throw MoleProbeError.invalidResponse("unknown or repeated unprotected path")
        }
        return rest.filter(open.contains)
    }

    /// A completed list is NUL-separated and ends with an empty record. EOF alone proves
    /// nothing: even a successful early exit must not turn a truncated answer into protection.
    private static func recordPrefix(_ data: Data) throws -> (records: [String], length: Int)? {
        var records: [String] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            if index == start { return (records, index + 1 - data.startIndex) }
            guard let value = String(data: data[start..<index], encoding: .utf8) else {
                throw MoleProbeError.invalidResponse("non-UTF-8 record")
            }
            records.append(value)
            start = index + 1
        }
        return nil
    }

    private static func completeRecords(_ data: Data) throws -> [String] {
        guard let frame = try recordPrefix(data), frame.length == data.count else {
            throw MoleProbeError.invalidResponse("missing completion record or trailing data")
        }
        return frame.records
    }

    /// As `is_path_whitelisted` compares: one trailing slash dropped, runs of slashes collapsed.
    static func normalized(_ path: String) -> String {
        var out = path.hasSuffix("/") ? String(path.dropLast()) : path
        while out.contains("//") { out = out.replacingOccurrences(of: "//", with: "/") }
        return out
    }

    static func probeEnvironment(_ home: URL) -> [String: String] {
        ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval = 120,
                    cancellation: MoleProbeCancellation = MoleProbeCancellation()) throws -> String {
        let result = try ManagedProbe.run(executable, arguments, environment: environment,
                                          timeout: timeout, cancellation: cancellation)
        guard result.succeeded else {
            throw MoleProbeError.io("\(executable) \(arguments.prefix(2)) exited \(result.status)")
        }
        return result.stdout
    }
}
