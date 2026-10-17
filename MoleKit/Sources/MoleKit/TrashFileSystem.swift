import CPTYShim
import Darwin
import Foundation

final class TrashDirectory {
    let descriptor: Int32
    init(_ descriptor: Int32, operation: String) throws {
        guard descriptor >= 0 else { throw TrashFS.error(operation) }
        self.descriptor = descriptor
    }
    deinit { _ = nora_trash_close(descriptor) }
}

enum TrashFS {
    static let journalLimit = 32 * 1024 * 1024
    static func error(_ operation: String) -> TrashSafetyError {
        .io("\(operation): \(String(cString: strerror(errno)))")
    }
    static func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else { throw error(operation) }
    }
    static func open(_ url: URL) throws -> TrashDirectory {
        try TrashDirectory(nora_trash_open_absolute_directory(url.path), operation: "open directory")
    }
    static func open(_ name: String, in parent: TrashDirectory) throws -> TrashDirectory {
        try TrashDirectory(nora_trash_open_directory(parent.descriptor, name), operation: "open \(name)")
    }
    static func identity(_ directory: TrashDirectory) throws -> TrashFileIdentity {
        var value = nora_trash_identity()
        try check(nora_trash_fstat(directory.descriptor, &value), "inspect directory")
        return try convert(value)
    }
    static func identity(_ name: String, in parent: TrashDirectory) throws -> TrashFileIdentity {
        var value = nora_trash_identity()
        try check(nora_trash_stat(parent.descriptor, name, &value), "inspect \(name)")
        return try convert(value)
    }
    static func optionalIdentity(_ name: String, in parent: TrashDirectory) throws -> TrashFileIdentity? {
        var value = nora_trash_identity()
        if nora_trash_stat(parent.descriptor, name, &value) == 0 { return try convert(value) }
        if errno == ENOENT { return nil }
        throw error("inspect \(name)")
    }
    private static func convert(_ value: nora_trash_identity) throws -> TrashFileIdentity {
        let type: TrashEntryType
        switch value.mode & UInt32(S_IFMT) {
        case UInt32(S_IFREG): type = .file
        case UInt32(S_IFDIR): type = .directory
        case UInt32(S_IFLNK): type = .symbolicLink
        default: throw TrashSafetyError.incomplete("unsupported filesystem object")
        }
        return TrashFileIdentity(device: value.device, inode: value.inode, ownerID: value.owner,
                                 mode: value.mode, type: type, size: value.size,
                                 modifiedSeconds: value.modified_seconds, modifiedNanoseconds: value.modified_nanoseconds,
                                 changedSeconds: value.changed_seconds, changedNanoseconds: value.changed_nanoseconds,
                                 birthSeconds: value.birth_seconds, birthNanoseconds: value.birth_nanoseconds)
    }
    static func names(_ directory: TrashDirectory, maximum: Int = 50_000) throws -> [String] {
        var bytes: UnsafeMutablePointer<CChar>?
        var count = 0
        try check(nora_trash_list(directory.descriptor, &bytes, &count, 16 * 1024 * 1024, maximum), "read directory")
        defer { nora_trash_free(bytes) }
        guard let bytes else { return [] }
        let data = Data(bytes: bytes, count: count)
        let names = try data.split(separator: 0).map {
            guard let name = String(data: Data($0), encoding: .utf8), validComponent(name) else {
                throw TrashSafetyError.incomplete("a filename cannot be represented safely")
            }
            return name
        }.sorted()
        guard Set(names).count == names.count else {
            throw TrashSafetyError.incomplete("ambiguous or duplicate filenames")
        }
        return names
    }
    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }
    static func validPath(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { validComponent(String($0)) }
    }
    static func sync(_ directory: TrashDirectory) throws {
        try check(nora_trash_sync(directory.descriptor), "sync directory")
    }
    static func make(_ name: String, in parent: TrashDirectory) throws -> TrashDirectory {
        try check(nora_trash_mkdir(parent.descriptor, name), "create private directory")
        try sync(parent)
        return try open(name, in: parent)
    }
    static func requireNoACL(_ directory: TrashDirectory) throws {
        try check(nora_trash_require_no_acl(directory.descriptor), "verify private staging ACL")
    }
    static func requireNoGrantACL(_ directory: TrashDirectory) throws {
        try check(nora_trash_require_no_grant_acl(directory.descriptor), "verify staging ancestor ACL")
    }
    static func move(_ name: String, from source: TrashDirectory, to destination: TrashDirectory, as slot: String) throws {
        try check(nora_trash_rename_exclusive(source.descriptor, name, destination.descriptor, slot), "move without replacing \(name)")
        try sync(source)
        try sync(destination)
    }
    static func remove(_ name: String, in parent: TrashDirectory, directory: Bool) throws {
        try unlink(name, in: parent, directory: directory)
        try sync(parent)
    }
    static func unlink(_ name: String, in parent: TrashDirectory, directory: Bool) throws {
        try check(nora_trash_unlink(parent.descriptor, name, directory ? 1 : 0), "remove captured \(name)")
    }
    static func removeJournalTemporary(_ name: String, in parent: TrashDirectory) throws {
        try check(nora_trash_remove_journal_temporary(parent.descriptor, name, journalLimit), "remove incomplete journal metadata")
    }
    static func write<T: Encodable>(_ journal: T, name: String = "journal.json", in directory: TrashDirectory) throws {
        let bytes = try JSONEncoder().encode(journal)
        guard bytes.count <= journalLimit else { throw TrashSafetyError.incomplete("recovery journal exceeds its limit") }
        try bytes.withUnsafeBytes {
            try check(nora_trash_write_metadata(directory.descriptor, name, ".journal-\(UUID().uuidString)",
                                               $0.baseAddress, $0.count), "durably write recovery journal")
        }
    }
    static func read<T: Decodable>(_ type: T.Type, name: String = "journal.json", in directory: TrashDirectory) throws -> T {
        var bytes: UnsafeMutableRawPointer?
        var count = 0
        try check(nora_trash_read_metadata(directory.descriptor, name, &bytes, &count, journalLimit), "read recovery metadata")
        defer { nora_trash_free(bytes) }
        guard let bytes else { throw TrashSafetyError.recoveryRequired("empty journal") }
        return try JSONDecoder().decode(type, from: Data(bytes: bytes, count: count))
    }
}
