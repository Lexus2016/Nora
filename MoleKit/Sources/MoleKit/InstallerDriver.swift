import Foundation

/// One row of `mo installer`'s selection menu, e.g. `➤ ● Setup.dmg   1.5MB | Downloads`.
public struct InstallerRow: Equatable, Sendable {
    public let isCursor: Bool
    public let isSelected: Bool
    public let name: String
    public let size: String
    public let source: String
}

/// One file to delete: its name as the menu shows it (possibly cut with "..."), the sources it
/// may come from and, from the app, the size the user saw. The menu never shows a full path, so
/// the visible name, folder and size together are the file's identity: a different file that
/// shares a cut name must also share the folder and the size to stand in, or the run is refused.
public struct InstallerTarget: Hashable, Sendable {
    public let name: String
    public let sources: Set<String>
    public let size: String?

    public init(name: String, sources: Set<String>, size: String? = nil) {
        self.name = name
        self.sources = sources
        self.size = size
    }
}

public enum InstallerDriverError: Error, Equatable {
    case targetNotListed(String)
    case targetListedTwice(String)
    case sourceNotAllowed(name: String, source: String)
    /// The name is still listed but its size changed since the preview: another file now.
    case targetChanged(String)
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
        try delete(names.map { InstallerTarget(name: $0, sources: allowedSources) }, in: session)
    }

    /// Deletes exactly `targets`: each must match one menu row by name and source, and the review
    /// list (full names) must map one to one onto them before the final Enter.
    public func delete(_ targets: [InstallerTarget], in session: PTYSession) throws {
        let names = targets.map(\.name)
        let menu = try wait(session, "installer menu") { lines in
            lines.contains { $0.hasPrefix(Self.menuTitle) } && lines.contains { $0.contains("Space Select") }
        }
        let rows = Self.parseRows(menu)
        let chosen: Set<Int>
        do {
            chosen = try plan(rows, menu: menu, targets: targets)
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
        guard Self.review(listed, matches: targets) else {
            session.send(.escape)
            throw InstallerDriverError.reviewMismatch(expected: names.sorted(), onScreen: listed.sorted())
        }
        session.send(.enter)
    }

    /// The review prints full names; every target (menu name, maybe cut) must account for exactly
    /// one of them and no listed file may be left over.
    static func review(_ listed: [String], matches targets: [InstallerTarget]) -> Bool {
        guard listed.count == targets.count, Set(listed).count == listed.count else { return false }
        var used = Set<String>()
        for target in targets {
            let hits = listed.filter { !used.contains($0) && name(target.name, matches: $0) }
            guard hits.count == 1 else { return false }
            used.insert(hits[0])
        }
        return used.count == listed.count
    }

    /// `name` as the menu shows it against a full file name.
    static func name(_ shown: String, matches full: String) -> Bool {
        shown == full || (shown.hasSuffix("...") && full.hasPrefix(String(shown.dropLast(3))))
    }

    /// Maps each requested name to exactly one menu row, or refuses.
    private func plan(_ rows: [InstallerRow], menu: [String], targets: [InstallerTarget]) throws -> Set<Int> {
        // A scroll indicator ("[3/40]") means rows are off screen; the spike does not scroll.
        if menu.contains(where: { $0.hasPrefix(Self.menuTitle + " [") }) {
            throw InstallerDriverError.paginated
        }
        let preselected = rows.filter(\.isSelected).map(\.name)
        guard preselected.isEmpty else { throw InstallerDriverError.preselected(preselected) }
        var chosen = Set<Int>()
        for target in targets.sorted(by: { $0.name < $1.name }) {
            let byName = rows.indices.filter { Self.row(rows[$0], shows: target.name) }
            guard !byName.isEmpty else { throw InstallerDriverError.targetNotListed(target.name) }
            // The name and the source together pick the row; the same name in another folder is
            // a different file and never stands in for the one the user saw.
            let fromSource = byName.filter { target.sources.contains(rows[$0].source) }
            guard !fromSource.isEmpty else {
                throw InstallerDriverError.sourceNotAllowed(name: target.name, source: rows[byName[0]].source)
            }
            let matches = fromSource.filter { Self.row(rows[$0], is: target) }
            guard let index = matches.first else { throw InstallerDriverError.targetChanged(target.name) }
            // Two rows with the same visible name and source, or two targets behind one row: refuse.
            guard matches.count == 1, chosen.insert(index).inserted else {
                throw InstallerDriverError.targetListedTwice(target.name)
            }
        }
        return chosen
    }

    /// Everything the user saw about the file: cut or full name, folder and size.
    static func row(_ row: InstallerRow, is target: InstallerTarget) -> Bool {
        Self.row(row, shows: target.name) && target.sources.contains(row.source) && (target.size.map { $0 == row.size } ?? true)
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
