import Foundation
import MoleKit

/// The summary block Mole prints at the end of clean, optimize, purge and installer runs, in
/// Nora's language. The headings and detail lines are a fixed set (bin/*.sh in 1.59); sizes and
/// counts are kept and shown in Nora's format. Lines Nora wrote itself, and anything unknown,
/// pass through unchanged.
enum MoleSummaryText {
    static func localize(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if let fixed = fixed[line] { return fixed }
        if let m = line.firstMatch(of: #/^Applied (\d+) optimizations(?:, (.+))?$/#) {
            let done = String(localized: "Tasks done: \(String(m.1))")
            guard let stat = m.2 else { return done }
            return done + " · " + keyStat(String(stat))
        }
        if let m = line.firstMatch(of: #/^Would apply (\d+) optimizations$/#) {
            return String(localized: "Tasks to run: \(String(m.1))")
        }
        if line.firstMatch(of: #/^\d+ (unchanged|skipped|unavailable|need attention|failed)( \| \d+ (unchanged|skipped|unavailable|need attention|failed))*$/#) != nil {
            return line.components(separatedBy: " | ").map(outcome).joined(separator: " · ")
        }
        if let m = line.firstMatch(of: #/^Tracked cleanup: (.+?)(?: \| Items cleaned: (\d+))?$/#) {
            let freed = String(localized: "Cleaned: \(size(m.1))")
            return m.2.map { freed + " · " + String(localized: "Items: \(String($0))") } ?? freed
        }
        if let m = line.firstMatch(of: #/^Free space: (\S+)(?: \((.+)\))?$/#) {
            let free = String(localized: "Free on disk: \(size(m.1))")
            return m.2.map { "\(free) (\(signedSize($0)))" } ?? free
        }
        if let m = line.firstMatch(of: #/^(Estimated space freed|Would free approximately): (\S+)(?: \+ (\d+) unmeasured)?(?: \| Items: (\d+))?(?: \| Free: (\S+))?$/#) {
            var parts = [m.1 == "Estimated space freed" ? String(localized: "Freed about \(size(m.2))") : String(localized: "Would free about \(size(m.2))")]
            if let unmeasured = m.3 { parts[0] += " " + String(localized: "and \(String(unmeasured)) more not measured") }
            if let items = m.4 { parts.append(String(localized: "Folders: \(String(items))")) }
            if let free = m.5 { parts.append(String(localized: "Free on disk: \(size(free))")) }
            return parts.joined(separator: " · ")
        }
        if let m = line.firstMatch(of: #/^Potential space: (.+?)(?: \| Items: (\d+))?(?: \| Categories: (\d+))?$/#) {
            var parts = [String(localized: "Can be freed: \(size(m.1))")]
            if let items = m.2 { parts.append(String(localized: "Items: \(String(items))")) }
            if let categories = m.3 { parts.append(String(localized: "Categories: \(String(categories))")) }
            return parts.joined(separator: " · ")
        }
        if let m = line.firstMatch(of: #/^(Removed|Would remove) (\d+) installers, (?:freed|free) ([\d.]+)MB$/#) {
            let freed = Format.bytes(Int64((Double(String(m.3)) ?? 0) * 1_000_000))
            return m.1 == "Removed"
                ? String(localized: "Installers removed: \(String(m.2)), \(freed) freed")
                : String(localized: "Installers to remove: \(String(m.2)), \(freed) to free")
        }
        if let m = line.firstMatch(of: #/^Failed to remove (\d+) installers?$/#) {
            return String(localized: "Installers that could not be removed: \(String(m.1))")
        }
        if let m = line.firstMatch(of: #/^Skipped (\d+) project scan roots? because scanning did not complete:?$/#) {
            return String(localized: "Some project folders could not be checked completely (\(String(m.1)) skipped).")
        }
        if let m = line.firstMatch(of: #/^Skipped (\d+) cloud-synced \S+ in non-interactive mode \(confirmation required\)$/#) {
            return String(localized: "Cloud-synced folders skipped: \(String(m.1)). Mole removes those only after a confirmation in Terminal.")
        }
        if let m = line.firstMatch(of: #/^Detailed file list: (.+)$/#) {
            return String(localized: "Full list: \(String(m.1))")
        }
        return line
    }

    private static func keyStat(_ stat: String) -> String {
        if let m = stat.firstMatch(of: #/^(\S+) cache cleaned$/#) { return String(localized: "cache cleaned: \(size(m.1))") }
        if let m = stat.firstMatch(of: #/^(\d+) databases optimized$/#) { return String(localized: "databases optimized: \(String(m.1))") }
        if let m = stat.firstMatch(of: #/^(\d+) configs repaired$/#) { return String(localized: "settings repaired: \(String(m.1))") }
        return stat
    }

    private static func outcome(_ part: String) -> String {
        guard let m = part.firstMatch(of: #/^(\d+) (.+)$/#) else { return part }
        let n = String(m.1)
        return switch m.2 {
        case "unchanged": String(localized: "Already fine: \(n)")
        case "skipped": String(localized: "Skipped: \(n)")
        case "unavailable": String(localized: "Unavailable: \(n)")
        case "need attention": String(localized: "Need attention: \(n)")
        case "failed": String(localized: "Failed: \(n)")
        default: part
        }
    }

    /// "12.3GB" in Nora's format; text that is not a size ("Partially measured") passes through.
    private static func size(_ text: Substring) -> String {
        let value = String(text)
        if value == "Partially measured" { return String(localized: "partly measured") }
        if let at = value.firstMatch(of: #/^At least (\S+)$/#) { return String(localized: "at least \(size(at.1))") }
        return MoleSize.parse(value).map { Format.bytes($0) } ?? value
    }

    private static func signedSize(_ text: Substring) -> String {
        guard let sign = text.first, sign == "+" || sign == "-" else { return size(text) }
        return String(sign) + size(text.dropFirst())
    }

    private static let fixed: [String: String] = [
        "Optimization Complete": String(localized: "Maintenance finished"),
        "Dry Run Complete, No Changes Made": String(localized: "Check finished, nothing changed"),
        "Optimization pass complete": String(localized: "Every task was checked."),
        "Review the warnings above": String(localized: "Some tasks need attention. Show the log for details."),
        "Run without --dry-run to apply these changes": String(localized: "This was only a check."),
        "Cleanup complete": String(localized: "Cleanup finished"),
        "Cleanup incomplete": String(localized: "Cleanup did not finish"),
        "Cleanup cancelled": String(localized: "Cleanup was cancelled"),
        "Cleanup interrupted": String(localized: "Cleanup was interrupted"),
        "Dry run complete - no changes made": String(localized: "Check finished, nothing changed"),
        "Dry run incomplete": String(localized: "The check did not finish"),
        "Dry run incomplete - no changes made": String(localized: "The check did not finish, nothing changed"),
        "Dry run cancelled": String(localized: "The check was cancelled"),
        "Dry run interrupted": String(localized: "The check was interrupted"),
        "No additional reclaimable space detected.": String(localized: "Nothing more to free."),
        "No additional space freed.": String(localized: "No more space was freed."),
        "No significant reclaimable space detected, system already clean.": String(localized: "Your Mac is already clean."),
        "System was already clean; no additional space freed.": String(localized: "Your Mac was already clean."),
        "Use mo clean --whitelist to add protection rules": String(localized: "To keep something from being cleaned, add it in Protection."),
        "Cleanup preview file could not be written safely": String(localized: "Mole could not save the list of found files."),
        "Purge complete": String(localized: "Build folders removed"),
        "Purge incomplete": String(localized: "Build folder removal did not finish"),
        "No artifacts were removed.": String(localized: "No build folders were removed."),
        "Some artifacts were skipped or could not be processed.": String(localized: "Some build folders were skipped or could not be removed."),
        "Installers cleaned": String(localized: "Installers removed"),
        "Installer cleanup incomplete": String(localized: "Installer removal did not finish"),
        "No installers were removed": String(localized: "No installers were removed."),
        "Your Mac is cleaner now!": String(localized: "Your Mac is cleaner now."),
    ]
}
