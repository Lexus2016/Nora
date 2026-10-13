import Foundation

/// Reads of an app bundle: its size, its last-used date, and the unused rule. Called off the
/// main thread; the callers keep the results.
enum AppUsage {
    static let unusedAfter: TimeInterval = 90 * 24 * 60 * 60

    /// True when the app was last opened 90 days or more before `now`. An unknown date is not
    /// counted as unused: Nora does not guess.
    static func isUnused(lastUsed: Date?, now: Date) -> Bool {
        guard let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) >= unusedAfter
    }

    /// Spotlight's last-used date, else the bundle's access date. Read this before the bundle is
    /// walked: walking it can touch the access date.
    static func lastUsed(path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        if let item = NSMetadataItem(url: url), let date = item.value(forAttribute: "kMDItemLastUsedDate") as? Date {
            return date
        }
        return (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }

    /// Allocated bytes of every regular file under the bundle.
    static func allocatedSize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let file = walker.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
