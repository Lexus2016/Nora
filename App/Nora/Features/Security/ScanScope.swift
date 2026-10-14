import Foundation
import SwiftUI

/// Quick checks launch items and the usual download folders. Full covers the home folder.
enum ScanScope: String, CaseIterable, Identifiable, Sendable {
    case quick, full

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .quick: "Quick"
        case .full: "Full"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .quick: "Launch items, Applications, Downloads and Desktop."
        case .full: "Your home folder. iCloud folders are skipped."
        }
    }
}

enum ScanCadence: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }
}

/// The paths and counts a scan will cover. `skippedICloud` counts iCloud folders left out of Full.
struct ScanPlan: Equatable, Sendable {
    var roots: [String]
    var skippedICloud: Int
}

enum ScanPlanner {
    static func plan(_ scope: ScanScope, home: URL, launchPaths: [String],
                     fileManager: FileManager = .default) -> ScanPlan {
        switch scope {
        case .quick:
            let candidates = launchPaths.filter { !$0.hasPrefix("/System/") }
                + ["/Applications", home.appendingPathComponent("Downloads").path, home.appendingPathComponent("Desktop").path]
            return ScanPlan(roots: unique(candidates.filter { fileManager.fileExists(atPath: $0) }), skippedICloud: 0)
        case .full:
            return fullPlan(home: home, fileManager: fileManager)
        }
    }

    static func fullPlan(home: URL, fileManager: FileManager = .default) -> ScanPlan {
        let excluded = ["Library/CloudStorage", "Library/Mobile Documents"]
        let skipped = excluded.filter { fileManager.fileExists(atPath: home.appendingPathComponent($0).path) }.count
        var roots: [String] = []
        for name in childNames(of: home, fileManager) {
            if name == "Library" {
                let library = home.appendingPathComponent("Library", isDirectory: true)
                for child in childNames(of: library, fileManager) where !excluded.contains("Library/" + child) {
                    roots.append(library.appendingPathComponent(child).path)
                }
            } else {
                roots.append(home.appendingPathComponent(name).path)
            }
        }
        return ScanPlan(roots: unique(roots), skippedICloud: skipped)
    }

    /// The roots with `excluded` folders cut out: a root that contains one is replaced by its
    /// children, down to the excluded folder's siblings. yara cannot skip a folder itself, so
    /// Nora's own quarantine and database are left out this way; a root inside one is dropped.
    static func excluding(_ excluded: [String], from roots: [String], fileManager: FileManager = .default) -> [String] {
        let excluded = excluded.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var out: [String] = []
        func add(_ root: String) {
            if excluded.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) { return }
            guard excluded.contains(where: { $0.hasPrefix(root + "/") }) else { return out.append(root) }
            for name in childNames(of: URL(fileURLWithPath: root), fileManager) { add(root + "/" + name) }
        }
        roots.forEach(add)
        return out
    }

    /// Names, not URLs: `contentsOfDirectory` may return a resolved path (/private/var for /var), and the
    /// roots must stay under the home folder the caller passed in.
    private static func childNames(of directory: URL, _ fileManager: FileManager) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// Timing rules as pure functions, so they can be tested without the clock or UserDefaults.
enum ScanSchedule {
    static func isDue(now: Date, last: Date?, cadence: ScanCadence) -> Bool {
        isDue(now: now, last: last, interval: cadence.interval)
    }

    /// ClamAV's database is refreshed at most once a day.
    static func isUpdateDue(now: Date, last: Date?) -> Bool {
        isDue(now: now, last: last, interval: 86_400)
    }

    private static func isDue(now: Date, last: Date?, interval: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

/// Security settings in UserDefaults. Every toggle is off until the user turns it on.
enum SecuritySettings {
    static let scheduleKey = "security.schedule.enabled"
    static let cadenceKey = "security.schedule.cadence"
    static let scopeKey = "security.schedule.scope"
    static let watchKey = "security.downloadsWatch.enabled"
    private static let lastScheduledKey = "security.schedule.last"
    private static let lastUpdateKey = "security.clamav.lastUpdate"

    static var scheduleEnabled: Bool { UserDefaults.standard.bool(forKey: scheduleKey) }

    static var cadence: ScanCadence {
        ScanCadence(rawValue: UserDefaults.standard.string(forKey: cadenceKey) ?? "") ?? .daily
    }

    static var scope: ScanScope {
        ScanScope(rawValue: UserDefaults.standard.string(forKey: scopeKey) ?? "") ?? .quick
    }

    static var watchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: watchKey) }
        set { UserDefaults.standard.set(newValue, forKey: watchKey) }
    }

    static var lastScheduledScan: Date? {
        get { UserDefaults.standard.object(forKey: lastScheduledKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastScheduledKey) }
    }

    static var lastDatabaseUpdate: Date? {
        get { UserDefaults.standard.object(forKey: lastUpdateKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastUpdateKey) }
    }
}
