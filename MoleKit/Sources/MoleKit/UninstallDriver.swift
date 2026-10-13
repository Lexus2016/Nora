import Foundation

public enum UninstallDriverError: Error, Equatable {
    /// `mo uninstall <name>` matched a different set of apps than the one requested.
    case matchMismatch(expected: String, onScreen: [String])
    /// The removal plan differs from what Nora previewed; nothing was removed.
    case planMismatch(unexpected: [String], missing: [String])
}

/// Drives `mo uninstall <name>` (Mole 1.59) through both of its confirmations.
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
        // Matching first scans every app (12–20 s on a cold cache).
        let matched = try session.awaitMoleScreen(timeout: scanTimeout, "app match") { lines in
            lines.contains { $0.hasPrefix("Proceed with uninstallation? [y/N]") }
        }
        let apps = Self.parseMatches(matched)
        guard apps == [name] else {
            session.write("n\r")
            throw UninstallDriverError.matchMismatch(expected: name, onScreen: apps)
        }
        session.write("y\r")

        let review = try session.awaitMoleScreen(timeout: scanTimeout, "removal plan") { lines in
            lines.contains("Files to be removed:") && lines.contains { $0.contains("Enter confirm, ESC cancel") }
        }
        let plan = RemovalList(review) ?? RemovalList()
        let listed = Set(plan.entries)
        guard plan.groups == [name], listed == expectedEntries, listed.count == plan.entries.count else {
            session.send(.escape)
            throw UninstallDriverError.planMismatch(
                unexpected: listed.subtracting(expectedEntries).sorted(),
                missing: expectedEntries.subtracting(listed).sorted()
            )
        }
        session.send(.enter)
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
