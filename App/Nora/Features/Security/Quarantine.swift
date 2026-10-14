import CryptoKit
import Foundation

/// One quarantined file and the facts needed to restore it.
struct QuarantineEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let originalPath: String
    let fileName: String
    let sha256: String
    let posixMode: Int
    let detection: String
    let date: Date
}

enum QuarantineError: LocalizedError {
    case missingFile(String)
    case targetExists(String)
    case alreadyQuarantined(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): String(localized: "\(name) is no longer in quarantine.")
        case .targetExists(let path): String(localized: "A file already exists at \(path). Move it away first.")
        case .alreadyQuarantined(let name): String(localized: "\(name) is already in quarantine.")
        }
    }
}

/// `Quarantine/<uuid>/` holds `meta.json` and the file as `payload/<original name>` (mode 0600), so
/// a file named meta.json never collides with it. Entries from before 1.2 keep the file next to
/// `meta.json` and are still listed and restored. Every call here is a user action.
struct QuarantineStore: Sendable {
    let root: URL

    func list() -> [QuarantineEntry] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder -> QuarantineEntry? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
            return try? decoder.decode(QuarantineEntry.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    /// Where an entry's file is: `payload/<name>`, or next to meta.json for an older entry.
    func storedFile(_ entry: QuarantineEntry) -> URL {
        let folder = root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let payload = folder.appendingPathComponent("payload", isDirectory: true).appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: payload.path) || !FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry.fileName).path)
            ? payload : folder.appendingPathComponent(entry.fileName)
    }

    /// True for a path inside this quarantine.
    func contains(_ path: String) -> Bool {
        let rootPath = root.standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(rootPath + "/")
    }

    @discardableResult
    func move(_ file: URL, detection: String, now: Date = .now) throws -> QuarantineEntry {
        let fileManager = FileManager.default
        // A file already in quarantine stays in its entry; moving it again would split the entry.
        guard !contains(file.path) else { throw QuarantineError.alreadyQuarantined(file.lastPathComponent) }
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let entry = QuarantineEntry(id: UUID(), originalPath: file.path, fileName: file.lastPathComponent,
                                    sha256: try Self.sha256(of: file), posixMode: mode,
                                    detection: detection, date: now)
        let folder = root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let stored = folder.appendingPathComponent("payload", isDirectory: true).appendingPathComponent(entry.fileName)

        try fileManager.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(entry).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
            try fileManager.moveItem(at: file, to: stored)
        } catch {
            // Nothing was moved yet, or the move itself failed: the original file is still in place.
            try? fileManager.removeItem(at: folder)
            throw error
        }
        // The file is already safe in quarantine; dropping the execute bits is best effort.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stored.path)
        return entry
    }

    func restore(_ entry: QuarantineEntry) throws {
        let fileManager = FileManager.default
        let folder = root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let stored = storedFile(entry)
        let target = URL(fileURLWithPath: entry.originalPath)
        guard fileManager.fileExists(atPath: stored.path) else { throw QuarantineError.missingFile(entry.fileName) }
        guard !fileManager.fileExists(atPath: target.path) else { throw QuarantineError.targetExists(entry.originalPath) }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: stored, to: target)
        try? fileManager.setAttributes([.posixPermissions: entry.posixMode], ofItemAtPath: target.path)
        try? fileManager.removeItem(at: folder)
    }

    /// Permanent deletion. The caller must have shown a confirmation first.
    func delete(_ entry: QuarantineEntry) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.id.uuidString, isDirectory: true))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
