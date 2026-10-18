import Foundation

/// Known Mole 1.59–1.61 task names in Nora's language; the installed backend supplies the task list.
/// Відомі назви завдань Mole 1.59–1.61 мовою Nora; список завдань надає встановлена версія.
/// Status lines
/// are free text with many variants; Nora shows its own words for the usual reasons a task needs
/// attention or was skipped, and any other line as Mole wrote it.
enum OptimizeText {
    static func title(_ mole: String) -> String { catalog[mole]?.title ?? mole }

    static func description(_ mole: String) -> String? { catalog[mole]?.detail }

    static func reason(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        for icon in ["→ ", "◎ ", "⊙ ", "- ", "✓ ", "• "] where line.hasPrefix(icon) { line.removeFirst(icon.count) }
        if let fixed = reasons[line] { return fixed }
        if line.hasSuffix(" · skipped (admin access required)") {
            return String(localized: "Skipped: this needs administrator rights.")
        }
        if line.hasSuffix(" skipped (database busy or locked)") {
            return String(localized: "Skipped: the database is busy. Try again later.")
        }
        if line.hasSuffix(" skipped (not available on this macOS version)") {
            return String(localized: "Not available on this version of macOS.")
        }
        if let m = line.firstMatch(of: #/^Close these apps before database optimization: (.+)$/#) {
            return String(localized: "Quit these apps first: \(String(m.1))")
        }
        if let m = line.firstMatch(of: #/^(\d+) broken login item\(s\) · remove via System Settings > General > Login Items$/#) {
            return String(localized: "Broken login items: \(String(m.1)). Remove them in System Settings → General → Login Items.")
        }
        if let m = line.firstMatch(of: #/^Broken login item: (.+) \(app not found\)$/#) {
            return String(localized: "Broken login item: \(String(m.1)) (the app is gone)")
        }
        if let m = line.firstMatch(of: #/^(\d+) Launch Agent\(s\) point at a missing program · left in ~/Library/LaunchAgents$/#) {
            return String(localized: "Background agents pointing at a missing app: \(String(m.1)). They are still in ~/Library/LaunchAgents.")
        }
        if let m = line.firstMatch(of: #/^Login items all healthy \((\d+) checked\)$/#) {
            return String(localized: "All login items work (\(String(m.1)) checked)")
        }
        return line
    }

    private static let reasons: [String: String] = [
        "Login items all healthy": String(localized: "All login items work"),
        "Disk issues detected · run: sudo diskutil repairVolume /":
            String(localized: "The disk has problems. Run in Terminal: sudo diskutil repairVolume /"),
        "Spotlight search is slow, rebuilding index, may take 1-2 hours":
            String(localized: "Spotlight search is slow, so its index is rebuilt. This can take 1–2 hours."),
        "Shared file lists not readable (check directory permissions and Full Disk Access)":
            String(localized: "Finder lists could not be read. Give Nora Full Disk Access."),
        "Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)":
            String(localized: "Disk check is off by default in Mole."),
        "Disk verify skipped":
            String(localized: "Disk check is off by default in Mole."),
        "sqlite3 not available": String(localized: "sqlite3 is not available on this Mac."),
        "Database optimization incomplete": String(localized: "Database optimization did not finish."),
        "Network health check timed out": String(localized: "The network check took too long."),
    ]

    private static let catalog: [String: (title: String, detail: String)] = [
        "DNS & Spotlight Check": (String(localized: "DNS and Spotlight check"), String(localized: "Refreshes the DNS cache and checks Spotlight.")),
        "Finder Cache Refresh": (String(localized: "Finder cache refresh"), String(localized: "Refreshes Quick Look thumbnails and the icon cache.")),
        "App State Cleanup": (String(localized: "Old app states"), String(localized: "Removes saved app states older than 30 days.")),
        "Broken Config Repair": (String(localized: "Broken settings repair"), String(localized: "Fixes damaged preference files.")),
        "Network Cache Refresh": (String(localized: "Network cache refresh"), String(localized: "Refreshes the DNS cache.")),
        "Database Optimization": (String(localized: "Database optimization"), String(localized: "Compacts the Mail, Safari and Messages databases while those apps are closed.")),
        "Prevent Finder .DS_Store": (String(localized: "No .DS_Store on drives"), String(localized: "Stops Finder from writing .DS_Store files on network and USB drives.")),
        "Legacy Overrides": (String(localized: "Old tweak leftovers"), String(localized: "Removes hidden App Nap and disk-image settings left by old tweak tools.")),
        "Network Stack Refresh": (String(localized: "Network stack refresh"), String(localized: "Flushes the routing table and ARP cache to fix network trouble.")),
        "Permission Repair": (String(localized: "Permission repair"), String(localized: "Fixes permission problems in your home folder.")),
        "Spotlight Optimization": (String(localized: "Spotlight speed"), String(localized: "Rebuilds the search index only if search is slow.")),
        "Spotlight Orphan Rules": (String(localized: "Spotlight leftovers"), String(localized: "Removes search rules of apps that are no longer installed.")),
        "Periodic Maintenance": (String(localized: "Periodic maintenance"), String(localized: "Runs macOS daily, weekly and monthly maintenance if it is overdue.")),
        "Shared File Lists": (String(localized: "Finder lists"), String(localized: "Repairs damaged Finder favorites and recent documents.")),
        "Disk Health": (String(localized: "Disk health"), String(localized: "Checks the file system.")),
        "Login Items": (String(localized: "Login items"), String(localized: "Looks for login items that no longer work.")),
        "Login Items Audit": (String(localized: "Login items"), String(localized: "Looks for login items that no longer work.")),
        "Quarantine Database Cleanup": (String(localized: "Download history"), String(localized: "Clears Gatekeeper's record of downloaded files.")),
        "Launch Agents Cleanup": (String(localized: "Background agents"), String(localized: "Reports background agents whose app is gone.")),
        "Notifications": (String(localized: "Notifications"), String(localized: "Removes old delivered notifications to keep their database small.")),
        "Usage Data": (String(localized: "Usage data"), String(localized: "Removes old usage tracking data.")),
    ]
}
