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

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): String(localized: "\(name) is no longer in quarantine.")
        case .targetExists(let path): String(localized: "A file already exists at \(path). Move it away first.")
        }
    }
}

/// `Quarantine/<uuid>/` holds the file (mode 0600) and `meta.json`. Every call here is a user action.
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

    @discardableResult
    func move(_ file: URL, detection: String, now: Date = .now) throws -> QuarantineEntry {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let entry = QuarantineEntry(id: UUID(), originalPath: file.path, fileName: file.lastPathComponent,
                                    sha256: try Self.sha256(of: file), posixMode: mode,
                                    detection: detection, date: now)
        let folder = root.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let stored = folder.appendingPathComponent(entry.fileName)

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
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
        let stored = folder.appendingPathComponent(entry.fileName)
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
