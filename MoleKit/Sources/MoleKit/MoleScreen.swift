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
///
/// Strict on purpose: the list is accepted only when every non-empty line up to the `➤` prompt is
/// a header or an entry and the prompt is on screen. A wrapped long path, an unexpected line or a
/// list that scrolled off the top makes it nil, and the drivers then refuse to confirm.
struct RemovalList: Equatable {
    var groups: [String] = []
    var entries: [String] = []

    init(groups: [String] = [], entries: [String] = []) {
        self.groups = groups
        self.entries = entries
    }

    init?(_ lines: [String]) {
        guard let start = lines.firstIndex(of: "Files to be removed:"),
              lines.lastIndex(of: "Files to be removed:") == start else { return nil }
        let rest = lines[(start + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The prompt is the one "➤" line and the last thing on screen. A file name that draws its
        // own "➤" (a carriage return inside it) cannot end the list early and hide what follows.
        guard let prompt = rest.last, prompt.hasPrefix("➤"), rest.filter({ $0.hasPrefix("➤") }).count == 1 else { return nil }
        for line in rest.dropLast() {
            if line.hasPrefix("◎ ") {
                groups.append(Self.stripSize(line.dropFirst(2)))
            } else if line.hasPrefix("✓ ") {
                entries.append(Self.stripSize(line.dropFirst(2)))
            } else {
                return nil
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
