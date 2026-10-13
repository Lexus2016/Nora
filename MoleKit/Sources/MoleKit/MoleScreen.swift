import Foundation

public enum MoleScreenError: Error, Equatable {
    /// sudo asked for a password on the terminal; drivers never answer it.
    case privilegePrompt
    /// Mole printed escape sequences the screen model does not know: its UI changed.
    case unknownTerminalSequences([String])
}

extension PTYSession {
    /// `waitUntil` for Mole's screens: stops on a password prompt (sending Ctrl-C)
    /// and on terminal drift, so a driver never acts on a screen it cannot read.
    @discardableResult
    func awaitMoleScreen(timeout: TimeInterval, _ what: String, _ predicate: ([String]) -> Bool) throws -> [String] {
        var sawPrompt = false
        let lines = try waitUntil(timeout: timeout, what) { lines in
            if lines.contains(where: { $0.contains("Password:") }) {
                sawPrompt = true
                return true
            }
            return predicate(lines)
        }
        if sawPrompt {
            send(.interrupt)
            throw MoleScreenError.privilegePrompt
        }
        let unknown = unknownSequences
        guard unknown.isEmpty else { throw MoleScreenError.unknownTerminalSequences(unknown) }
        return lines
    }
}

/// `Files to be removed:` lists as Mole prints them: an optional `◎ Group , total`
/// header per app, then `✓ entry , size` rows, ending at the `➤` prompt.
struct RemovalList: Equatable {
    var groups: [String] = []
    var entries: [String] = []

    init(groups: [String] = [], entries: [String] = []) {
        self.groups = groups
        self.entries = entries
    }

    init?(_ lines: [String]) {
        guard let start = lines.firstIndex(of: "Files to be removed:") else { return nil }
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("➤") { break }
            if trimmed.hasPrefix("◎ ") {
                groups.append(Self.stripSize(trimmed.dropFirst(2)))
            } else if trimmed.hasPrefix("✓ ") {
                entries.append(Self.stripSize(trimmed.dropFirst(2)))
            } else {
                break
            }
        }
    }

    private static func stripSize(_ text: Substring) -> String {
        guard let comma = text.range(of: " , ", options: .backwards) ?? text.range(of: ", ", options: .backwards) else {
            return String(text)
        }
        return text[..<comma.lowerBound].trimmingCharacters(in: .whitespaces)
    }
}
