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

    /// Reads the menu of `mo installer --dry-run` and quits it. Returns no rows when Mole
    /// found nothing and exited without showing the menu.
    public func list(in session: PTYSession, timeout: TimeInterval = 240) throws -> [InstallerRow] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = session.lines
            if lines.contains(where: { $0.hasPrefix(Self.menuTitle) }), lines.contains(where: { $0.contains("Space Select") }) {
                Thread.sleep(forTimeInterval: 0.3)
                let rows = Self.parseRows(session.lines)
                session.send(.character("q"))
                return rows
            }
            if session.exitStatus != nil { return [] }
            Thread.sleep(forTimeInterval: 0.1)
        }
        session.send(.character("q"))
        throw PTYError(description: "timed out waiting for the installer list")
    }

    /// - Parameters:
    ///   - names: file names exactly as Mole lists them.
    ///   - allowedSources: source labels the files may come from, e.g. `["Downloads", "Desktop"]`.
    ///     `Shared` (`/Users/Shared`) is the one label Mole derives outside `$HOME`.
    public func delete(_ names: Set<String>, allowedSources: Set<String>, in session: PTYSession) throws {
        let menu = try wait(session, "installer menu") { lines in
            lines.contains { $0.hasPrefix(Self.menuTitle) } && lines.contains { $0.contains("Space Select") }
        }
        let rows = Self.parseRows(menu)
        let chosen: Set<Int>
        do {
            chosen = try plan(rows, menu: menu, names: names, allowedSources: allowedSources)
        } catch {
            session.send(.character("q"))
            throw error
        }

        do {
            for index in rows.indices {
                if index > 0 {
                    session.send(.down)
                    try wait(session, "cursor on row \(index)") { Self.parseRows($0)[safe: index]?.isCursor == true }
                }
                if chosen.contains(index) {
                    session.send(.space)
                    try wait(session, "row \(index) selected") { Self.parseRows($0)[safe: index]?.isSelected == true }
                }
            }

            let onScreen = Self.parseRows(session.lines)
            let selected = Set(onScreen.indices.filter { onScreen[$0].isSelected })
            guard selected == chosen,
                  session.lines.contains(where: { $0.hasPrefix(Self.menuTitle) && $0.contains("\(names.count) selected") })
            else {
                throw InstallerDriverError.selectionMismatch(
                    expected: names.sorted(), onScreen: selected.sorted().map { onScreen[$0].name })
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

    /// Maps each requested name to exactly one menu row, or refuses.
    private func plan(_ rows: [InstallerRow], menu: [String], names: Set<String>, allowedSources: Set<String>) throws -> Set<Int> {
        // A scroll indicator ("[3/40]") means rows are off screen; the spike does not scroll.
        if menu.contains(where: { $0.hasPrefix(Self.menuTitle + " [") }) {
            throw InstallerDriverError.paginated
        }
        let preselected = rows.filter(\.isSelected).map(\.name)
        guard preselected.isEmpty else { throw InstallerDriverError.preselected(preselected) }
        var chosen = Set<Int>()
        for name in names.sorted() {
            let matches = rows.indices.filter { Self.row(rows[$0], shows: name) }
            guard let index = matches.first else { throw InstallerDriverError.targetNotListed(name) }
            // Two rows with the same visible prefix, or two targets behind one truncated row: refuse.
            guard matches.count == 1, chosen.insert(index).inserted else {
                throw InstallerDriverError.targetListedTwice(name)
            }
            guard allowedSources.contains(rows[index].source) else {
                throw InstallerDriverError.sourceNotAllowed(name: name, source: rows[index].source)
            }
        }
        return chosen
    }

    /// The menu cuts names to its column (20–40 cells) and appends "..."; the review list
    /// prints them in full and stays the final check.
    static func row(_ row: InstallerRow, shows name: String) -> Bool {
        if row.name == name { return true }
        guard row.name.hasSuffix("...") else { return false }
        return name.hasPrefix(String(row.name.dropLast(3)))
    }

    @discardableResult
    private func wait(_ session: PTYSession, _ what: String, _ predicate: ([String]) -> Bool) throws -> [String] {
        try session.awaitMoleScreen(timeout: timeout, what, predicate)
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
        RemovalList(lines)?.entries ?? []
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
