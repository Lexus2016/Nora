import Darwin
import Foundation

/// One Trash Nora may review and empty: the user's home Trash or a mounted disk's per-user Trash.
/// Один Кошик, який Nora може переглянути й очистити: домашній або Кошик підключеного диска.
public struct TrashLocation: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case home, volume }

    public let kind: Kind
    /// A stable display name: "Home" or the volume's name.
    public let label: String
    /// The directory that contains the Trash: the home folder or `<volume>/.Trashes`.
    public let parentPath: String
    /// `.Trash` in the home, the numeric user id on a volume.
    public let rootName: String
    /// Private staging on the same filesystem as the Trash (rename must never cross a device).
    public let stagingPath: String

    public var parentURL: URL { URL(fileURLWithPath: parentPath, isDirectory: true) }
    public var rootURL: URL { parentURL.appendingPathComponent(rootName, isDirectory: true) }
    public var stagingURL: URL { URL(fileURLWithPath: stagingPath, isDirectory: true) }

    /// Permanent deletion on a disk needs the same metadata the home engine relies on: stable
    /// ownership and mode bits, and extended attributes that do not turn into AppleDouble files.
    /// APFS and HFS+ provide that; exFAT and FAT (common on flash drives) do not, so Nora reviews
    /// their Trash but leaves emptying it to Finder.
    /// Постійне видалення на диску потребує тих самих метаданих, на які спирається домашній рушій:
    /// стабільних власника й режиму та розширених атрибутів, які не перетворюються на файли
    /// AppleDouble. APFS і HFS+ це дають; exFAT і FAT (типові для флешок) — ні, тому Nora показує
    /// їхній Кошик, але очищення лишає Finder.
    public var supportsPermanentDeletion: Bool {
        guard kind == .volume else { return true }
        var info = statfs()
        guard statfs(rootURL.path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { raw in
            raw.bindMemory(to: CChar.self).baseAddress.map(String.init(cString:)) ?? ""
        }
        return ["apfs", "hfs", "hfsx"].contains(type)
    }

    public static func home(_ home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            owner: UInt32 = UInt32(geteuid())) -> Self {
        TrashLocation(kind: .home, label: "Home", parentPath: home.path, rootName: ".Trash",
                      stagingPath: home.appendingPathComponent("Library/Application Support/Nora/TrashRecovery",
                                                               isDirectory: true).path)
    }

    /// `<mount>/.Trashes/<uid>` is where Finder moves items deleted from that volume.
    /// `<mount>/.Trashes/.NoraTrash-<uid>` is Nora's private staging on the same device.
    public static func volume(mount: URL, owner: UInt32 = UInt32(geteuid()), label: String? = nil) -> Self {
        let trashes = mount.appendingPathComponent(".Trashes", isDirectory: true)
        return TrashLocation(kind: .volume,
                             label: label ?? (try? mount.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? mount.lastPathComponent,
                             parentPath: trashes.path,
                             rootName: String(owner),
                             stagingPath: trashes.appendingPathComponent(".NoraTrash-\(owner)", isDirectory: true).path)
    }
}

public enum TrashLocations {
    /// The home Trash and the per-user Trash of every mounted local, writable volume that has one.
    /// Only volumes that already carry a Trash are returned: a missing one has nothing to review,
    /// and creating it here would change the disk merely because Nora was open.
    public static func mounted(owner: UInt32 = UInt32(geteuid()),
                               fileManager: FileManager = .default) -> [TrashLocation] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeNameKey]
        let urls = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var seen = Set<String>()
        var locations: [TrashLocation] = []
        for url in urls where url.path.hasPrefix("/Volumes/") {
            guard seen.insert(url.path).inserted else { continue }
            // A network share or a read-only image cannot receive Finder's Trash.
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsReadOnly != true else { continue }
            let location = TrashLocation.volume(mount: url, owner: owner, label: values.volumeName)
            var value = stat()
            guard lstat(location.rootURL.path, &value) == 0,
                  value.st_mode & S_IFMT == S_IFDIR else { continue }
            locations.append(location)
        }
        return locations.sorted { $0.rootURL.path < $1.rootURL.path }
    }
}
