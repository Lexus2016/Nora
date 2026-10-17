import Foundation

/// Mole prints decimal sizes ("738.8MB", "2.48GB", "0B"); `+` marks a lower bound.
public enum MoleSize {
    public static func parse(_ text: String) -> Int64? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where s.uppercased().hasSuffix(unit) {
            guard let value = Double(s.dropLast(unit.count).trimmingCharacters(in: .whitespaces)),
                  value.isFinite, value >= 0, value * factor < Double(Int64.max) else { return nil }
            return Int64(value * factor)
        }
        return nil
    }
}

// MARK: - mo clean --dry-run

/// The cleanup preview: per-path items from `~/.config/mole/clean-list.txt`, grouped by
/// section, plus the human summary lines from stdout.
public struct CleanPreview: Sendable {
    public struct Item: Sendable, Identifiable, Hashable {
        public let section: String
        public let path: String
        /// The row's measured bytes; 0 when Mole could not measure it (`sizeKnown` false).
        public let size: Int64
        public var sizeKnown = true
        /// A listed path whose size already includes this row ("counted under …").
        public var countedUnder: String?
        public var id: String { path }

        /// What this row adds to a total: nothing when its bytes are already in another row.
        public var addedSize: Int64 { countedUnder == nil ? size : 0 }
    }

    public struct Note: Sendable, Hashable {
        public let section: String
        public let text: String
    }

    public var items: [Item]
    /// Lines Mole marks as needing attention (◎) or informational (⊙): skipped Trash,
    /// sudo needed for system caches, large files to review.
    public var notes: [Note]
    public var potentialSize: Int64?
    public var needsSudoForSystem: Bool
    /// Aggregate file count from Mole, NOT the number of path rows (folders can contain files).
    public var reportedItemCount: Int? = nil
    public var unparsedRows: [String] = []
    public var isComplete = false

    /// One validation contract for initial review and the last pre-execution check.
    /// A missing list is empty only when Mole explicitly reports no reclaimable work.
    public static func validated(stdout: String, list: String?, listModified: Date?, since started: Date) -> CleanPreview? {
        let text = ANSIText.strip(stdout)
        guard text.contains("Dry run complete"), !text.contains("Dry run incomplete") else { return nil }
        if !text.contains("Detailed file list:") {
            let parsed = parse(cleanList: "", stdout: stdout)
            guard parsed.reportedItemCount == nil || parsed.reportedItemCount == 0,
                  parsed.potentialSize == nil || parsed.potentialSize == 0,
                  text.contains("No significant reclaimable space detected, system already clean.")
                    || (parsed.reportedItemCount == 0 && parsed.potentialSize == 0) else { return nil }
            var empty = parsed
            empty.isComplete = true
            return empty
        }
        guard let list, let listModified, listModified >= started else { return nil }
        var parsed = parse(cleanList: list, stdout: stdout)
        guard parsed.unparsedRows.isEmpty, !parsed.items.isEmpty,
              Set(parsed.items.map(\.path)).count == parsed.items.count,
              let reported = parsed.reportedItemCount, reported > 0 else { return nil }
        parsed.isComplete = true
        return parsed
    }

    public var sections: [String] {
        var seen = Set<String>()
        return items.map(\.section).filter { seen.insert($0).inserted }
    }

    public static func parse(cleanList: String, stdout: String) -> CleanPreview {
        var items: [Item] = []
        var section = ""
        var unparsed: [String] = []
        for raw in cleanList.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                section = String(line.dropFirst(4).dropLast(4))
                continue
            }
            // "<path>  # 4.0MB" or "  # size unknown", then optional ", 3 items" and
            // ", counted under <path>". Either path may itself contain "  # ", so the separator is
            // accepted only if unambiguous and followed by a known annotation schema.
            var search = line.startIndex..<line.endIndex
            var found: (path: String, size: Int64?, note: String)?
            var candidates = 0
            while let hash = line.range(of: "  # ", range: search) {
                let note = String(line[hash.upperBound...])
                let head = note.components(separatedBy: ", ")[0]
                if head == "size unknown" || MoleSize.parse(head) != nil {
                    found = (String(line[..<hash.lowerBound]), MoleSize.parse(head), note)
                    candidates += 1
                }
                search = hash.upperBound..<line.endIndex
            }
            guard candidates == 1, let found, found.path.hasPrefix("/"), !section.isEmpty,
                  !found.path.contains("\r"), !found.path.contains("\0") else {
                unparsed.append(line)
                continue
            }
            let head = found.note.components(separatedBy: ", ")[0]
            let suffix = String(found.note.dropFirst(head.count))
            guard suffix.isEmpty || suffix.range(of: #"^(?:, [0-9]+ items)?(?:, counted under /[^\r\n\x00]+)?$"#, options: .regularExpression) != nil else {
                unparsed.append(line)
                continue
            }
            let under = found.note.range(of: ", counted under ").map { String(found.note[$0.upperBound...]) }
            items.append(Item(section: section, path: found.path, size: found.size ?? 0, sizeKnown: found.size != nil, countedUnder: under))
        }

        var notes: [Note] = []
        var current = ""
        var potential: Int64?
        var needsSudo = false
        var counted: Int?
        for raw in stdout.split(separator: "\n") {
            let line = ANSIText.strip(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤ ") { current = String(line.dropFirst(2)); continue }
            if line.hasPrefix("◎ ") || line.hasPrefix("⊙ ") {
                let text = String(line.dropFirst(2))
                if text.localizedCaseInsensitiveContains("need sudo") { needsSudo = true }
                notes.append(Note(section: current, text: text))
            }
            if let range = line.range(of: "Items: ") {
                counted = Int(line[range.upperBound...].prefix(while: \.isNumber))
            }
            if let range = line.range(of: "Potential space: ") {
                potential = MoleSize.parse(String(line[range.upperBound...].prefix { $0 != " " && $0 != "|" }))
            }
        }
        return CleanPreview(items: items, notes: notes, potentialSize: potential, needsSudoForSystem: needsSudo,
                            reportedItemCount: counted, unparsedRows: unparsed)
    }
}

// MARK: - mo purge --dry-run

public struct PurgePreview: Sendable {
    public struct Item: Sendable, Identifiable, Hashable {
        public let path: String
        public let size: Int64
        public var id: String { path }
        /// The project folder: the path up to the artifact directory's parent.
        public var project: String { (path as NSString).deletingLastPathComponent }
    }

    public var items: [Item]
    public var totalSize: Int64?
    public var warnings: [String]
    public var isComplete: Bool

    /// Mole prints artifact paths with `~` for the home folder; `home` expands them back.
    public static func parse(_ stdout: String, home: URL) -> PurgePreview {
        var items: [Item] = []
        var warnings: [String] = []
        var total: Int64?
        // Complete only on Mole's own success line, never by default: an empty or broken run must
        // not read as "nothing else exists".
        var finished = false
        var incomplete = false
        var counted: Int?
        for raw in stdout.split(separator: "\n") {
            let line = ANSIText.strip(String(raw)).trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "[DRY RUN] ") {
                let rest = line[r.upperBound...]
                guard let comma = rest.range(of: ", ", options: .backwards) else { continue }
                var path = String(rest[..<comma.lowerBound])
                if path == "~" { path = home.path } else if path.hasPrefix("~/") { path = home.path + path.dropFirst(1) }
                items.append(Item(path: path, size: MoleSize.parse(String(rest[comma.upperBound...])) ?? 0))
            } else if line.hasPrefix("◎ ") {
                warnings.append(String(line.dropFirst(2)))
            } else if let r = line.range(of: "Would free approximately: ") {
                total = MoleSize.parse(String(line[r.upperBound...].prefix { $0 != " " && $0 != "|" }))
                if let i = line.range(of: "Items: ") { counted = Int(line[i.upperBound...].prefix(while: \.isNumber)) }
            } else if line.contains("Dry run incomplete") || line.contains("No artifacts found in the completed project scans") {
                incomplete = true
            } else if line.contains("Dry run complete") || line.contains("No old project artifacts to clean") {
                finished = true
            }
        }
        // Mole prints "Items: N" whenever it lists anything; listed rows without it are not a
        // complete answer.
        let complete = finished && !incomplete && (items.isEmpty ? counted == nil : counted == items.count)
        return PurgePreview(items: items, totalSize: total, warnings: warnings, isComplete: complete)
    }
}

// MARK: - mo optimize [--dry-run]

public struct OptimizeReport: Sendable {
    public enum Outcome: String, Sendable { case applied, unchanged, skipped, unavailable, attention }

    public struct Task: Sendable, Identifiable, Hashable {
        public let title: String
        public let lines: [String]
        public let outcome: Outcome
        public var id: String { title }
    }

    public var diagnosis: [String]
    public var tasks: [Task]
    /// "Would apply 4 optimizations" / "12 unchanged | 2 skipped | 2 unavailable".
    public var summary: [String]

    public static func parse(_ stdout: String) -> OptimizeReport {
        var diagnosis: [String] = []
        var tasks: [Task] = []
        var summary: [String] = []
        var title: String?
        var lines: [String] = []
        var inDiagnosis = false
        var inSummary = false

        func flush() {
            if let title { tasks.append(Task(title: title, lines: lines, outcome: classify(lines))) }
            title = nil
            lines = []
        }

        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = ANSIText.strip(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("=====") { flush(); inSummary.toggle(); continue }
            if inSummary { if !line.isEmpty { summary.append(line) }; continue }
            if line == "Performance diagnosis" { inDiagnosis = true; continue }
            if line.hasPrefix("➤ ") { flush(); inDiagnosis = false; title = String(line.dropFirst(2)); continue }
            guard !line.isEmpty else { continue }
            if inDiagnosis { diagnosis.append(line) } else if title != nil { lines.append(line) }
        }
        flush()
        return OptimizeReport(diagnosis: diagnosis, tasks: tasks, summary: summary)
    }

    static func classify(_ lines: [String]) -> Outcome {
        let text = lines.joined(separator: " ").lowercased()
        if lines.contains(where: { $0.hasPrefix("◎") }) { return .attention }
        if lines.contains(where: { $0.hasPrefix("- ") }) || text.contains("not available") || text.contains("unavailable") || text.contains("not readable") { return .unavailable }
        if text.contains("skipped") { return .skipped }
        if text.contains("already") || text.contains("healthy") || text.contains("all ") && text.contains("valid") || text.contains("no legacy") || text.contains("clean") && !text.contains("cleaned") { return .unchanged }
        return .applied
    }
}

// MARK: - mo uninstall --list (JSON when stdout is not a terminal)

public struct InstalledApp: Decodable, Sendable, Identifiable, Hashable {
    public let name: String
    public let bundleID: String?
    public let source: String?
    public let uninstallName: String
    public let path: String
    /// Mole prints "--" when the size is unknown.
    public let sizeText: String?

    public var id: String { path }
    public var size: Int64? { sizeText.flatMap(MoleSize.parse) }

    enum CodingKeys: String, CodingKey { case name, bundleID = "bundle_id", source, uninstallName = "uninstall_name", path, sizeText = "size" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        uninstallName = c.lenient(.uninstallName) ?? name
        bundleID = c.lenient(.bundleID)
        source = c.lenient(.source)
        sizeText = c.lenient(.sizeText)
    }

    public static func decodeList(_ data: Data) throws -> [InstalledApp] {
        try JSONDecoder().decode([InstalledApp].self, from: data)
    }
}

// MARK: - mo history --json

public struct MoleHistory: Decodable, Sendable {
    public struct Session: Decodable, Sendable, Identifiable, Hashable {
        public let command: String
        public let runID: String?
        public let startedAt: String?
        public let endedAt: String?
        public let items: Int
        public let sizeText: String?
        public let operationCount: Int
        public let failedTasks: Int
        public let removed, trashed, skipped, failed, rebuilt: Int

        public var id: String { (runID?.isEmpty == false ? runID! : nil) ?? "\(command)-\(startedAt ?? "")" }
        public var size: Int64 { sizeText.flatMap(MoleSize.parse) ?? 0 }
        public var started: Date? { startedAt.flatMap(Self.parseDate) }

        enum CodingKeys: String, CodingKey {
            case command, runID = "run_id", startedAt = "started_at", endedAt = "ended_at", items, sizeText = "size"
            case operationCount = "operation_count", failedTasks = "failed_tasks", actions
        }
        struct Actions: Decodable { var removed, trashed, skipped, failed, rebuilt: Int? }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = c.lenient(.command) ?? "?"
            runID = c.lenient(.runID); startedAt = c.lenient(.startedAt); endedAt = c.lenient(.endedAt)
            items = c.lenientInt(.items) ?? 0
            sizeText = c.lenient(.sizeText)
            operationCount = c.lenientInt(.operationCount) ?? 0
            failedTasks = c.lenientInt(.failedTasks) ?? 0
            let a: Actions? = c.lenient(.actions)
            removed = a?.removed ?? 0; trashed = a?.trashed ?? 0; skipped = a?.skipped ?? 0
            failed = a?.failed ?? 0; rebuilt = a?.rebuilt ?? 0
        }

        static func parseDate(_ s: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.date(from: s)
        }
    }

    public let sessions: [Session]

    enum CodingKeys: String, CodingKey { case sessions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = c.lenientArray(.sessions)
    }
}

// MARK: - mo analyze --json PATH

public struct DiskAnalysis: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Identifiable, Hashable {
        public let name: String
        public let path: String
        public let size: Int64
        public let isDirectory: Bool
        /// `complete`, `partial` (size is a lower bound) or `unavailable`.
        public let scanStatus: String?
        public var id: String { path }
        public var isPartial: Bool { scanStatus == "partial" }

        enum CodingKeys: String, CodingKey { case name, path, size, isDirectory = "is_dir", scanStatus = "scan_status" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            name = c.lenient(.name) ?? (path as NSString).lastPathComponent
            size = c.lenientInt64(.size) ?? 0
            isDirectory = c.lenient(.isDirectory) ?? false
            scanStatus = c.lenient(.scanStatus)
        }
    }

    public let path: String?
    public let scanStatus: String?
    public let entries: [Entry]
    public let largeFiles: [Entry]
    public let totalSize: Int64?
    public let totalFiles: Int?

    enum CodingKeys: String, CodingKey { case path, scanStatus = "scan_status", entries, largeFiles = "large_files", totalSize = "total_size", totalFiles = "total_files" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.lenient(.path); scanStatus = c.lenient(.scanStatus)
        entries = c.lenientArray(.entries); largeFiles = c.lenientArray(.largeFiles)
        totalSize = c.lenientInt64(.totalSize); totalFiles = c.lenientInt(.totalFiles)
    }
}

enum ANSIText {
    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
