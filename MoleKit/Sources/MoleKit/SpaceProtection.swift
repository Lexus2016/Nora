import Foundation

/// Paths Nora's Space Map must not move to the Trash. They are the ones Mole's own Analyze refuses
/// (cmd/analyze/delete.go, Mole 1.65 and 1.68): system roots, the home folder, Docker Desktop and
/// OrbStack state, and iCloud Drive's own folders. Trashing an iCloud Drive folder removes that
/// store from every device on the account; trashing app state loses a running app's data. Nora moves
/// items itself instead of asking Mole, so it must apply the same rules.
public enum SpaceProtection {
    public enum Reason: Sendable, Equatable {
        /// A system root or tree, or another account's home folder.
        case system
        /// The user's own home folder.
        case home
        /// Docker Desktop or OrbStack state, or a folder that holds it.
        case appState
        /// iCloud Drive's own folders, or a folder that holds them.
        case iCloud
    }

    /// Why `path` must not be moved to the Trash, or nil when it may be. Both the path as given and
    /// the one it resolves to are checked, so a symlink cannot reach a protected folder.
    public static func reason(forTrashing path: String, home: URL) -> Reason? {
        let fileManager = FileManager.default
        var spellings = [normalized(path)]
        let resolved = normalized(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        if resolved != spellings[0] { spellings.append(resolved) }
        var homes = [normalized(home.path)]
        let resolvedHome = normalized(home.resolvingSymlinksInPath().path)
        if resolvedHome != homes[0] { homes.append(resolvedHome) }
        for candidate in spellings {
            if let reason = check(candidate, homes: homes, fileManager: fileManager) { return reason }
        }
        return nil
    }

    private static let criticalRoots: Set<String> = [
        "/", "/Applications", "/Applications/Finder.app", "/Applications/Safari.app", "/Library", "/Library/Apple",
        "/Library/Application Support", "/Library/Extensions", "/Library/Keychains", "/System", "/Users", "/Volumes",
        "/Network", "/cores", "/dev", "/etc", "/home", "/net", "/tmp", "/var", "/private", "/private/etc", "/private/tmp",
        "/private/var", "/private/var/audit", "/private/var/db", "/private/var/root", "/private/var/tmp",
        "/private/var/folders", "/bin", "/sbin", "/usr", "/opt", "/opt/homebrew",
    ]

    private static let protectedTrees = [
        "/System", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/audit", "/private/var/db", "/private/var/root",
        "/Library/Apple", "/Library/Extensions", "/Library/Keychains", "/Applications/Finder.app", "/Applications/Safari.app", "/dev",
    ]

    private static func check(_ path: String, homes: [String], fileManager: FileManager) -> Reason? {
        if homes.contains(path) { return .home }
        if criticalRoots.contains(path) { return .system }
        // A folder directly under /Users is another account's home. Its contents stay its owner's to remove.
        if fileManager.fileExists(atPath: "/Users"), URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Users" {
            return .system
        }
        if protectedTrees.contains(where: { path.hasPrefix($0 + "/") }) { return .system }
        for home in homes {
            let dockerDesktop = home + "/Library/Containers/com.docker.docker"
            let orbStack = home + "/.orbstack"
            if covers(path, root: dockerDesktop, fileManager: fileManager) || covers(path, root: orbStack, fileManager: fileManager) {
                return .appState
            }
            if holdsOrbStackGroupContainer(path, home: home, fileManager: fileManager) { return .appState }
            if isICloudStructure(path, home: home, fileManager: fileManager) { return .iCloud }
        }
        return nil
    }

    /// `path` is `root`, lies inside it, or contains it. A root that does not exist protects only
    /// what lies inside its name: an absent runtime must not freeze an otherwise ordinary folder.
    private static func covers(_ path: String, root: String, fileManager: FileManager) -> Bool {
        if path == root || path.hasPrefix(root + "/") { return true }
        guard fileManager.fileExists(atPath: root) else { return false }
        return root.hasPrefix(path == "/" ? "/" : path + "/")
    }

    private static func holdsOrbStackGroupContainer(_ path: String, home: String, fileManager: FileManager) -> Bool {
        let groupContainers = home + "/Library/Group Containers"
        let names = (try? fileManager.contentsOfDirectory(atPath: groupContainers)) ?? []
        for name in names where name.lowercased().hasSuffix("dev.orbstack") {
            if covers(path, root: groupContainers + "/" + name, fileManager: fileManager) { return true }
        }
        // Inside such a container by name alone, even when it is not listed.
        let prefix = groupContainers.lowercased() + "/"
        guard path.lowercased().hasPrefix(prefix) else { return false }
        let container = path.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
        return container.lowercased().hasSuffix("dev.orbstack")
    }

    /// Mobile Documents, each app container in it (com~apple~CloudDocs is iCloud Drive itself) and a
    /// container's Documents folder. Files and folders inside those stay the user's to remove.
    private static func isICloudStructure(_ path: String, home: String, fileManager: FileManager) -> Bool {
        let mobileDocuments = home + "/Library/Mobile Documents"
        if path == mobileDocuments { return true }
        if fileManager.fileExists(atPath: mobileDocuments), mobileDocuments.hasPrefix(path == "/" ? "/" : path + "/") { return true }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue { return false }
        let prefix = mobileDocuments.lowercased() + "/"
        guard path.lowercased().hasPrefix(prefix) else { return false }
        let parts = path.lowercased().dropFirst(prefix.count).split(separator: "/")
        switch parts.count {
        case 1: return true
        case 2: return parts[1] == "documents"
        default: return false
        }
    }

    /// The path without `.`/`..`, and without the firmlink prefix macOS gives the data volume.
    private static func normalized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        let firmlink = "/System/Volumes/Data"
        if standard == firmlink { return "/" }
        if standard.hasPrefix(firmlink + "/") { return String(standard.dropFirst(firmlink.count)) }
        return standard
    }
}
