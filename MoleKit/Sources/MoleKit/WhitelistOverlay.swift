import Foundation

public enum WhitelistOverlayError: Error, Equatable {
    /// A previous run left a journal behind; call `recoverIfNeeded()` first.
    case pendingRecovery
    case io(String)
}

/// Temporarily protects extra paths from `mo clean` by appending a marked block to
/// Mole's whitelist, so unchecked items in Nora's review survive the run.
///
/// Mole treats an existing whitelist file as the complete list: writing one where
/// none existed would silently drop Mole's optional defaults. So when the file is
/// absent, the overlay first materializes those defaults (read from the installed
/// Mole, see `MoleInstallation.cleanWhitelistDefaults`), and restoring deletes the
/// file again instead of leaving it behind.
///
/// The original state is journaled and fsynced before the whitelist is touched, so a
/// crash at any point, including SIGKILL, is undone by `recoverIfNeeded()` on next launch.
public struct WhitelistOverlay: Sendable {
    /// The invoking user's home. Injected; Foundation's home lookup may ignore `$HOME`.
    public let home: URL
    public let journalURL: URL

    struct Journal: Codable {
        let runID: String
        let whitelistPath: String
        let originalContents: Data?
        let createdAt: Date
    }

    public init(home: URL, journalURL: URL) {
        self.home = home
        self.journalURL = journalURL
    }

    public var whitelistURL: URL {
        home.appendingPathComponent(".config/mole/whitelist")
    }

    public var needsRecovery: Bool {
        FileManager.default.fileExists(atPath: journalURL.path)
    }

    public func apply(protecting patterns: [String], defaults: [String], runID: String) throws {
        guard !needsRecovery else { throw WhitelistOverlayError.pendingRecovery }

        // Dotfile managers often symlink the whitelist; write through to the real file.
        let target = whitelistURL.resolvingSymlinksInPath()
        let original = FileManager.default.fileExists(atPath: target.path)
            ? try read(target)
            : nil

        let journal = Journal(runID: runID, whitelistPath: target.path, originalContents: original, createdAt: Date())
        try Self.writeDurably(try JSONEncoder().encode(journal), to: journalURL)

        var text: String
        if let original {
            text = String(decoding: original, as: UTF8.self)
        } else {
            text = "# Mole's optional defaults, written by Nora for one clean run and removed afterwards.\n"
            text += defaults.map { $0 + "\n" }.joined()
        }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "# >>> nora-overlay \(runID)\n"
        text += patterns.map { $0 + "\n" }.joined()
        text += "# <<< nora-overlay \(runID)\n"
        try Self.writeDurably(Data(text.utf8), to: target)
    }

    /// Ends one operation's overlay: restores only when the journal belongs to `runID`, so an
    /// operation never removes the protection another one is still running under.
    public func recover(runID: String) throws {
        guard needsRecovery else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: try read(journalURL))
        guard journal.runID == runID else { return }
        try restore(journal)
    }

    /// Puts the whitelist back exactly as the journal recorded it, whoever wrote it. Only for
    /// launch and quit, when no operation is running (crash recovery).
    public func recoverIfNeeded() throws {
        guard needsRecovery else { return }
        try restore(try JSONDecoder().decode(Journal.self, from: try read(journalURL)))
    }

    private func restore(_ journal: Journal) throws {
        let target = URL(fileURLWithPath: journal.whitelistPath)

        if let original = journal.originalContents {
            try Self.writeDurably(original, to: target)
        } else if FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                throw WhitelistOverlayError.io("remove \(target.path): \(error.localizedDescription)")
            }
            Self.syncDirectory(target.deletingLastPathComponent())
        }

        do {
            try FileManager.default.removeItem(at: journalURL)
        } catch {
            throw WhitelistOverlayError.io("remove journal: \(error.localizedDescription)")
        }
        Self.syncDirectory(journalURL.deletingLastPathComponent())
    }

    /// The whitelist as the user keeps it: while a run's overlay is applied, the copy saved in
    /// the journal, otherwise the file. Nil when the user has no whitelist file. Editors read
    /// this, so a run's temporary entries never turn into permanent rules.
    public func userWhitelist() -> String? {
        if let data = try? read(journalURL), let journal = try? JSONDecoder().decode(Journal.self, from: data) {
            return journal.originalContents.map { String(decoding: $0, as: UTF8.self) }
        }
        return try? String(contentsOf: whitelistURL, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw WhitelistOverlayError.io("read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Write to a temporary sibling, fsync it, rename over the target, fsync the directory.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).nora-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw WhitelistOverlayError.io("create \(temporary.path)")
            }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch let error as WhitelistOverlayError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw WhitelistOverlayError.io("write \(url.path): \(error.localizedDescription)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw WhitelistOverlayError.io("rename onto \(url.path): \(reason)")
        }
        syncDirectory(directory)
    }

    static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }
}
