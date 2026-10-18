import Foundation

public enum UninstallDriverError: Error, Equatable {
    /// `mo uninstall <name>` matched a different set of apps than the one requested.
    case matchMismatch(expected: String, onScreen: [String])
    /// The removal plan differs from what Nora previewed; nothing was removed.
    case planMismatch(unexpected: [String], missing: [String])
    /// The removal plan on screen could not be read completely (a wrapped line, an unexpected line,
    /// or a list taller than the screen); nothing was removed.
    case unreadablePlan
    case appIsRunning
}

/// Drives `mo uninstall <name>` through its app match, data selection and final confirmation.
/// Керує вибором програми, даних і остаточним підтвердженням у `mo uninstall <name>`.
///
/// 1. "Matched N app(s)" must list exactly the requested app before it answers `y`.
/// 2. "Files to be removed:" must list exactly `expectedEntries` (as Mole prints them,
///    `~/…` for the home) before it presses Enter; otherwise it cancels with ESC.
///
/// Piping `y` to stdin, as other wrappers do, also confirms the second prompt blind:
/// without a TTY the read hits EOF, which Mole treats as Enter.
public struct UninstallDriver {
    /// Scanning apps and leftovers can take a while on a full disk.
    public var scanTimeout: TimeInterval = 180

    public init() {}

    public func uninstall(app name: String, expectedEntries: Set<String>, in session: PTYSession) throws {
        let plan = try review(app: name, in: session)
        guard !Self.showsRunningApp(session.lines) else {
            session.send(.escape)
            throw UninstallDriverError.appIsRunning
        }
        let listed = Set(plan.entries)
        guard listed == expectedEntries else {
            session.send(.escape)
            throw UninstallDriverError.planMismatch(
                unexpected: listed.subtracting(expectedEntries).sorted(),
                missing: expectedEntries.subtracting(listed).sorted()
            )
        }
        session.send(.enter)
    }

    /// Runs inside `mo uninstall --dry-run <name>`: confirms the match, reads the removal plan
    /// and cancels with ESC. Returns the entries as Mole prints them (`~/…` for the home).
    public func preview(app name: String, in session: PTYSession) throws -> [String] {
        let plan = try review(app: name, in: session)
        session.send(.escape)
        return plan.entries
    }

    private func review(app name: String, in session: PTYSession) throws -> RemovalList {
        let matched = try session.awaitMoleScreen(timeout: scanTimeout, "app match") { lines in
            lines.contains { $0.hasPrefix("Proceed with uninstallation? [y/N]") }
        }
        let apps = Self.parseMatches(matched)
        guard apps == [name] else {
            session.write("n\r")
            throw UninstallDriverError.matchMismatch(expected: name, onScreen: apps)
        }
        session.write("y\r")
        var plan = try removalPlan(app: name, in: session)
        guard !plan.personalData.isEmpty else { return plan }

        // Include personal data in Nora's review, never approve its deletion before that review.
        // Додати особисті дані до перегляду Nora, не підтверджуючи їх видалення до цього перегляду.
        let personalData = Set(plan.personalData)
        let expected = Set(plan.entries).union(personalData)
        session.send(.character("d"))
        let menu = try session.awaitMoleScreen(timeout: scanTimeout, "personal data selection") { lines in
            lines.contains { $0.hasPrefix("Personal data to remove") } && lines.contains { $0.contains("Enter Save") }
        }
        guard Self.personalDataMenu(menu, paths: personalData, selected: false) else {
            session.send(.character("q"))
            throw UninstallDriverError.unreadablePlan
        }
        session.send(.character("a"))
        let selected = try session.awaitMoleScreen(timeout: scanTimeout, "selected personal data") { lines in
            Self.personalDataMenu(lines, paths: personalData, selected: true)
        }
        guard Self.personalDataMenu(selected, paths: personalData, selected: true) else {
            session.send(.character("q"))
            throw UninstallDriverError.unreadablePlan
        }
        session.send(.enter)
        plan = try removalPlan(app: name, in: session)
        guard plan.personalData.isEmpty, Set(plan.entries) == expected else {
            session.send(.escape)
            throw UninstallDriverError.planMismatch(
                unexpected: Set(plan.entries).subtracting(expected).sorted(),
                missing: expected.subtracting(plan.entries).sorted())
        }
        return plan
    }

    private func removalPlan(app name: String, in session: PTYSession) throws -> RemovalList {
        let lines = try session.awaitMoleScreen(timeout: scanTimeout, "removal plan") { lines in
            lines.contains("Files to be removed:") && lines.contains { $0.contains("Enter confirm, ESC cancel") }
        }
        guard let plan = RemovalList(lines, allowingPersonalData: true),
              plan.groups == [name] || plan.groups == [name + " [Brew]"],
              !plan.entries.isEmpty, Set(plan.entries).count == plan.entries.count,
              (plan.entries + plan.personalData).allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("~/") }) else {
            session.send(.escape)
            throw UninstallDriverError.unreadablePlan
        }
        return plan
    }

    static func personalDataMenu(_ lines: [String], paths: Set<String>, selected: Bool) -> Bool {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let count = selected ? paths.count : 0
        let title = "Personal data to remove \(count)/\(paths.count) selected"
        guard let first = lines.first,
              first.split(whereSeparator: \.isWhitespace).joined(separator: " ") == title,
              lines.suffix(2) == ["↑↓ | Space Select | A All | Enter Save | Q Cancel", "/ Search | h/l Page"] else { return false }
        var listed: [String] = []
        var cursors = 0
        for var line in lines.dropFirst().dropLast(2) {
            if line.hasPrefix("➤ ") { cursors += 1; line = String(line.dropFirst(2)) }
            guard line.hasPrefix(selected ? "● " : "○ ") else { return false }
            listed.append(String(line.dropFirst(2)))
        }
        return cursors == 1 && listed.count == paths.count && Set(listed) == paths
    }

    static func showsRunningApp(_ lines: [String]) -> Bool {
        lines.contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("➤ Remove ") && line.contains("[Running]") && line.contains("Enter confirm, ESC cancel")
        }
    }

    /// `1. Slack  512MB  |  Last: Today` → `Slack`.
    public static func parseMatches(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.contains("Matched ") && $0.contains("app(s):") }) else { return [] }
        var names: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dot = trimmed.firstIndex(of: "."), Int(trimmed[..<dot]) != nil else { break }
            let rest = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            let name = rest.range(of: "  ").map { rest[..<$0.lowerBound] } ?? Substring(rest)
            names.append(String(name))
        }
        return names
    }
}
