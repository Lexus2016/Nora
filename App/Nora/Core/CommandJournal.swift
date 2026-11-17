import Foundation
import os

/// What Nora ran, kept after the window and the app are gone. The console shows a command only
/// while Nora is open and holds 60 of them in memory, so after a restart nothing says what happened.
///
/// Every command is written when it starts and again when it ends: its result, the time it took and,
/// for a command that did not succeed, the last lines it printed. A start with no end means Nora was
/// stopped while it ran. The same lines go to the unified log (subsystem `io.github.lexus2016.nora`,
/// category `commands`). The record is two files of at most `limit` bytes: when the newer one fills up
/// it replaces the older. Nothing here can fail a command: a write error is dropped.
final class CommandJournal: Sendable {
    static let subsystem = "io.github.lexus2016.nora"
    /// Lines of output kept for a command that did not succeed.
    static let tailLines = 20
    private static let longestLine = 300

    private let url: URL
    private let limit: Int
    private let queue = DispatchQueue(label: "io.github.lexus2016.nora.command-journal", qos: .utility)
    private let logger = Logger(subsystem: CommandJournal.subsystem, category: "commands")

    init(url: URL, limit: Int = 256 * 1024) {
        self.url = url
        self.limit = limit
    }

    /// The older of the two files.
    var olderURL: URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(name).1.\(url.pathExtension)")
    }

    /// A fact worth having next to the commands: a version, where Mole was found.
    func session(_ text: String, now: Date = Date()) {
        write(Self.line(now, "note", text))
    }

    func started(id: UUID, command: String, now: Date = Date()) {
        write(Self.line(now, "start \(Self.tag(id))", command))
    }

    /// `status` is the exit status; `failure` says why a command ended without one (stopped, could not start).
    func finished(id: UUID, command: String, started: Date, status: Int32?, failure: String?,
                  tail: [String], now: Date = Date()) {
        let took = String(format: "%.1f s", max(0, now.timeIntervalSince(started)))
        let result: String
        if let failure { result = "failed: \(failure)" }
        else if let status { result = "exit \(status)" }
        else { result = "ended" }
        var text = Self.line(now, "end \(Self.tag(id))", "\(result) (\(took))  \(command)")
        if failure != nil || status != 0 {
            for line in tail.suffix(Self.tailLines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                text += "    | \(Self.clip(line))\n"
            }
        }
        write(text)
    }

    /// Waits until everything queued so far is on disk. For tests.
    func flush() { queue.sync {} }

    static func tag(_ id: UUID) -> String { "[\(id.uuidString.prefix(8).lowercased())]" }

    static func line(_ date: Date, _ kind: String, _ text: String) -> String {
        "\(Date.ISO8601FormatStyle(timeZone: .current).format(date)) \(kind)  \(clip(text))\n"
    }

    private static func clip(_ text: String) -> String {
        text.count > longestLine ? String(text.prefix(longestLine)) + "…" : text
    }

    private func write(_ text: String) {
        logger.info("\(text.trimmingCharacters(in: .newlines), privacy: .public)")
        queue.async { [url, limit, older = olderURL] in
            let manager = FileManager.default
            func open() throws -> FileHandle {
                if !manager.fileExists(atPath: url.path) {
                    // Paths of the user's files appear in it: readable by the user only.
                    manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                return try FileHandle(forWritingTo: url)
            }
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var handle = try open()
                defer { try? handle.close() }
                // The size comes from the open file: `URL.resourceValues` caches it and would never see the file grow.
                if try handle.seekToEnd() > UInt64(limit) {
                    try handle.close()
                    try? manager.removeItem(at: older)
                    try manager.moveItem(at: url, to: older)
                    handle = try open()
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: Data(text.utf8))
            } catch {
                // A record that cannot be written must never stop the command it describes.
            }
        }
    }
}
