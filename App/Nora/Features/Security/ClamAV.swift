import Foundation
import MoleKit

/// Homebrew binaries. Nora never installs anything itself; installs run only on the user's click.
enum BrewTools {
    /// clamd is a daemon, so Homebrew links it into sbin, not bin.
    static let directories = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]

    /// ProcessRunner replaces the whole environment, and brew refuses to run without HOME, so the
    /// inherited variables stay and only PATH and Homebrew's own switches are set.
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
            .merging(["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
            .merging(Homebrew.variables) { $1 }
    }

    static func locate(_ name: String) -> URL? {
        directories.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var brew: URL? { locate("brew") }
}

/// ClamAV command-line tools from Homebrew. Nora runs them as separate processes and never links libclamav.
struct ClamAVTools: Equatable, Sendable {
    let clamscan: URL?
    let freshclam: URL?
    let clamd: URL?
    let clamdscan: URL?

    static func locate() -> ClamAVTools {
        ClamAVTools(clamscan: BrewTools.locate("clamscan"), freshclam: BrewTools.locate("freshclam"),
                    clamd: BrewTools.locate("clamd"), clamdscan: BrewTools.locate("clamdscan"))
    }

    var isInstalled: Bool { clamscan != nil && freshclam != nil }
}

/// Scanners that Nora started and then lost because it crashed or was force quit: their parent
/// is launchd and their command line names Nora's own ClamAV folder. Left alone, such a scan
/// keeps a core busy for hours and nobody reads its result. Nora ends them at launch.
enum ClamAVOrphans {
    static let names: Set<String> = ["clamscan", "clamd", "clamdscan", "freshclam"]

    static func reap(root: URL) async {
        let env = ["PATH": "/bin:/usr/bin", "LC_ALL": "C"]
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,ppid=,command="], environment: env) else { return }
        for pid in orphans(in: result.stdout, root: root.path) {
            // Read the process again right before the signal: the pid may belong to someone else by now.
            guard let again = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "pid=,ppid=,command=", "-p", String(pid)], environment: env),
                  orphans(in: again.stdout, root: root.path) == [pid] else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// `ps -axo pid=,ppid=,command=` lines whose parent is launchd (1), whose program is a ClamAV
    /// tool and whose arguments carry exactly the options Nora passes: `-d <root>/database` or
    /// `--config-file <root>/clamd.conf` / `freshclam.conf`. A bare mention of the folder is not enough.
    static func orphans(in ps: String, root: String) -> [pid_t] {
        let markers = [" -d \(root)/database ", " --config-file \(root)/clamd.conf ", " --config-file \(root)/freshclam.conf "]
        return ps.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), parts[1] == "1" else { return nil }
            let command = String(parts[2]) + " "
            let program = command.split(separator: " ").first.map { String($0.split(separator: "/").last ?? "") } ?? ""
            return names.contains(program) && markers.contains(where: command.contains) ? pid : nil
        }
    }
}

/// Nora's own ClamAV folder under Application Support: configs and the virus database.
struct ClamAVLayout: Sendable {
    let root: URL

    var database: URL { root.appendingPathComponent("database", isDirectory: true) }
    var freshclamConfig: URL { root.appendingPathComponent("freshclam.conf") }
    var clamdConfig: URL { root.appendingPathComponent("clamd.conf") }
    var socket: URL { root.appendingPathComponent("clamd.sock") }

    /// Any main or daily database file means a scan can run.
    var hasDatabase: Bool {
        ["main.cvd", "main.cld", "daily.cvd", "daily.cld"].contains {
            FileManager.default.fileExists(atPath: database.appendingPathComponent($0).path)
        }
    }

    func writeConfigs() throws {
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let freshclam = """
        DatabaseDirectory \(database.path)
        DatabaseMirror database.clamav.net
        ConnectTimeout 30
        ReceiveTimeout 120

        """
        try freshclam.write(to: freshclamConfig, atomically: true, encoding: .utf8)
        let clamd = """
        DatabaseDirectory \(database.path)
        LocalSocket \(socket.path)

        """
        try clamd.write(to: clamdConfig, atomically: true, encoding: .utf8)
    }
}

/// Parses `clamscan` and `clamdscan` output with `--infected --no-summary`.
/// Detections look like `/path/to/file: Signature.Name FOUND`. Exit status 1 means detections were found,
/// 2 means some errors happened; infections take priority over errors (ClamAV clamscan/manager.c).
enum ClamScanParser {
    struct Detection: Equatable, Sendable {
        let path: String
        let signature: String
    }

    struct Output: Equatable, Sendable {
        var detections: [Detection] = []
        /// Lines reporting a file that could not be read or scanned.
        var errors = 0
    }

    static func parse(_ text: String) -> Output {
        var output = Output()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(" FOUND") {
                let body = line.dropLast(" FOUND".count)
                // Split at the last ": " so colons inside the path stay in the path.
                guard let colon = body.range(of: ": ", options: .backwards) else { continue }
                let path = body[..<colon.lowerBound]
                let signature = body[colon.upperBound...]
                if !path.isEmpty, !signature.isEmpty {
                    output.detections.append(Detection(path: String(path), signature: String(signature)))
                }
            } else if line.hasPrefix("ERROR:") || line.hasSuffix(" ERROR") {
                output.errors += 1
            }
        }
        return output
    }

    /// Arguments for one scan over the given roots. `-d` points at Nora's database, not Homebrew's.
    static func arguments(database: URL, roots: [String]) -> [String] {
        ["-r", "--infected", "--no-summary", "-d", database.path] + roots
    }
}
