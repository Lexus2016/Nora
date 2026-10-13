import Foundation

/// Apple's XProtect rules, run through `yara`. The rules file is read where macOS keeps it;
/// Nora never copies or bundles it.
enum XProtect {
    static let rulesPath = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.yara"

    static var rulesURL: URL? {
        FileManager.default.isReadableFile(atPath: rulesPath) ? URL(fileURLWithPath: rulesPath) : nil
    }

    /// yara takes one target per run, so the scan calls it once per root.
    static func arguments(rules: URL, root: String) -> [String] {
        ["-r", "-w", rules.path, root]
    }
}

/// Parses default yara output: one `RULE_NAME /absolute/path` line per match.
enum YaraParser {
    struct Match: Equatable, Sendable {
        let rule: String
        let path: String
    }

    static func parse(_ text: String) -> [Match] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, isIdentifier(parts[0]), parts[1].hasPrefix("/") else { return nil }
            return Match(rule: String(parts[0]), path: String(parts[1]))
        }
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
