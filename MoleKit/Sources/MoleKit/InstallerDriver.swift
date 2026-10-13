import Foundation

/// One row of `mo installer`'s selection menu, e.g. `➤ ● Setup.dmg   1.5MB | Downloads`.
public struct InstallerRow: Equatable, Sendable {
    public let isCursor: Bool
    public let isSelected: Bool
    public let name: String
    public let size: String
    public let source: String
}

public enum InstallerDriverError: Error, Equatable {
    case targetNotListed(String)
    case targetListedTwice(String)
    case sourceNotAllowed(name: String, source: String)
    case preselected([String])
    case paginated
    case selectionMismatch(expected: [String], onScreen: [String])
    case reviewMismatch(expected: [String], onScreen: [String])
    case privilegePrompt
    case unknownTerminalSequences([String])
}

/// Drives `mo installer` (Mole 1.59) to delete exactly the named files and nothing else.
///
/// Every keystroke is followed by a check of the redrawn screen. Before the final
/// confirmation, the review list must equal the requested set; otherwise the driver
/// cancels with ESC and throws. It never presses `A` (all) or `I` (invert).
public struct InstallerDriver {
    public static let menuTitle = "Select Installers to Remove"
    public var timeout: TimeInterval = 30

    public init() {}

    /// - Parameters:
    ///   - names: file names exactly as Mole lists them.
    ///   - allowedSources: source labels the files may come from, e.g. `["Downloads", "Desktop"]`.
    ///     `Shared` (`/Users/Shared`) is the one label Mole derives outside `$HOME`.
    public func delete(_ names: Set<String>, allowedSources: Set<String>, in session: PTYSession) throws {
        let menu = try wait(session, "installer menu") { lines in
            lines.contains { $0.hasPrefix(Self.menuTitle) } && lines.contains { $0.contains("Space Select") }
        }
        let rows = Self.parseRows(menu)
        do {
            try validate(rows, menu: menu, names: names, allowedSources: allowedSources)
        } catch {
            session.send(.character("q"))
            throw error
        }

        do {
            for (index, row) in rows.enumerated() {
                if index > 0 {
                    session.send(.down)
                    try wait(session, "cursor on row \(index)") { Self.parseRows($0)[safe: index]?.isCursor == true }
                }
                if names.contains(row.name) {
                    session.send(.space)
                    try wait(session, "row \(index) selected") { Self.parseRows($0)[safe: index]?.isSelected == true }
                }
            }

            let selected = Self.parseRows(session.lines).filter(\.isSelected).map(\.name)
            guard Set(selected) == names, selected.count == names.count,
                  session.lines.contains(where: { $0.hasPrefix(Self.menuTitle) && $0.contains("\(names.count) selected") })
            else {
                throw InstallerDriverError.selectionMismatch(expected: names.sorted(), onScreen: selected.sorted())
            }
        } catch {
            session.send(.character("q"))
            throw error
        }

        session.send(.enter)
        let review = try wait(session, "review list") { lines in
            lines.contains("Files to be removed:") && lines.contains { $0.contains("Delete \(names.count) installer") }
        }
        let listed = Self.parseReview(review)
        guard Set(listed) == names, listed.count == names.count else {
            session.send(.escape)
            throw InstallerDriverError.reviewMismatch(expected: names.sorted(), onScreen: listed.sorted())
        }
        session.send(.enter)
    }

    private func validate(_ rows: [InstallerRow], menu: [String], names: Set<String>, allowedSources: Set<String>) throws {
        // A scroll indicator ("[3/40]") means rows are off screen; the spike does not scroll.
        if menu.contains(where: { $0.hasPrefix(Self.menuTitle + " [") }) {
            throw InstallerDriverError.paginated
        }
        let preselected = rows.filter(\.isSelected).map(\.name)
        guard preselected.isEmpty else { throw InstallerDriverError.preselected(preselected) }
        for name in names.sorted() {
            let matches = rows.filter { $0.name == name }
            guard let match = matches.first else { throw InstallerDriverError.targetNotListed(name) }
            guard matches.count == 1 else { throw InstallerDriverError.targetListedTwice(name) }
            guard allowedSources.contains(match.source) else {
                throw InstallerDriverError.sourceNotAllowed(name: name, source: match.source)
            }
        }
    }

    /// Waits for a screen state, aborting on a password prompt or terminal drift.
    @discardableResult
    private func wait(_ session: PTYSession, _ what: String, _ predicate: ([String]) -> Bool) throws -> [String] {
        var sawPrompt = false
        let lines = try session.waitUntil(timeout: timeout, what) { lines in
            if lines.contains(where: { $0.contains("Password:") }) {
                sawPrompt = true
                return true
            }
            return predicate(lines)
        }
        if sawPrompt {
            session.send(.interrupt)
            throw InstallerDriverError.privilegePrompt
        }
        let unknown = session.unknownSequences
        guard unknown.isEmpty else { throw InstallerDriverError.unknownTerminalSequences(unknown) }
        return lines
    }

    public static func parseRows(_ lines: [String]) -> [InstallerRow] {
        lines.compactMap { line in
            let isCursor = line.hasPrefix("➤ ")
            guard isCursor || line.hasPrefix("  ") else { return nil }
            let rest = line.dropFirst(2)
            guard let mark = rest.first, mark == "○" || mark == "●", rest.dropFirst().first == " " else { return nil }
            let body = rest.dropFirst(2)
            guard let bar = body.range(of: " | ", options: .backwards) else { return nil }
            let left = body[..<bar.lowerBound]
            let source = body[bar.upperBound...].trimmingCharacters(in: .whitespaces)
            // The name is padded to a column; a run of two spaces separates it from the size.
            guard let gap = left.range(of: "  ") else { return nil }
            return InstallerRow(
                isCursor: isCursor,
                isSelected: mark == "●",
                name: String(left[..<gap.lowerBound]),
                size: left[gap.upperBound...].trimmingCharacters(in: .whitespaces),
                source: source
            )
        }
    }

    /// Names under "Files to be removed:", each printed as `✓ <name> , <size>`.
    public static func parseReview(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(of: "Files to be removed:") else { return [] }
        var names: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("✓ ") else { break }
            let entry = trimmed.dropFirst(2)
            guard let comma = entry.range(of: ", ", options: .backwards) else { break }
            names.append(entry[..<comma.lowerBound].trimmingCharacters(in: .whitespaces))
        }
        return names
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
