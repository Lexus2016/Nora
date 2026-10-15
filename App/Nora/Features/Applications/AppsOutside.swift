import Foundation
import MoleKit

/// Updates for apps installed outside Homebrew and the App Store, such as from a DMG. An app with
/// its own Sparkle feed (`SUFeedURL`) is checked against that feed; any other app against
/// Homebrew's public cask catalog. A cask counts only when it installs the app under the same file
/// name AND names its exact bundle ID, so two apps that share a name (Telegram.app) never pick the
/// wrong cask. An update is reported only when the version is strictly newer; anything that does
/// not compare cleanly (a beta against a release, a build against a marketing version) is skipped.
/// Parsing and matching are pure, so they are tested offline.
///
/// Updating: when the matched cask is newer and installs nothing but the app, Nora sets the old
/// copy aside, runs `brew install --cask`, checks the new bundle and only then moves the old copy
/// to the Trash, so from then on Homebrew updates the app. Any other app gets Open: its own
/// updater installs the new version.
enum OutsideApps {
    /// One installed app that neither Homebrew nor the App Store manages.
    struct Local: Hashable, Sendable {
        let path: String
        let name: String
        let bundleID: String
        let version: String
        let build: String?
        let feed: URL?
        /// The bundle itself is writable, so Nora can move it aside. An app its own updater installed
        /// as root (Google Chrome) is not: moving a folder to another folder needs write access to
        /// the folder itself.
        var movable = true
        var fileName: String { (path as NSString).lastPathComponent }
    }

    enum Action: Hashable, Sendable {
        /// Old copy to the Trash, then `brew install --cask <token>`.
        case brew(String)
        /// Open the app; it updates itself.
        case open
    }

    struct Update: Identifiable, Hashable, Sendable {
        let path: String
        let name: String
        let bundleID: String
        let installed: String
        let latest: String
        let action: Action
        /// True when `latest` and `installed` are build numbers, not marketing versions.
        var builds = false
        var id: String { path }
        var token: String? { if case .brew(let token) = action { token } else { nil } }
    }

    /// One cask of the catalog, reduced to what matching needs.
    struct Cask: Hashable, Sendable {
        let token: String
        let version: String
        let autoUpdates: Bool
        /// Installed `.app` names, from the `app` artifacts.
        let apps: [String]
        /// Every string of the artifacts (uninstall and zap entries carry bundle IDs).
        let strings: [String]
        /// The cask installs only the app: no pkg, installer, binary, script or dependency.
        let installsOnlyApp: Bool
    }

    static let catalogURL = "https://formulae.brew.sh/api/cask.json"

    /// Artifact keys that install nothing besides the app (`uninstall` and `zap` run on removal).
    static let appOnlyArtifacts: Set<String> = ["app", "target", "uninstall", "zap"]
    /// Requirements Homebrew checks without installing anything else.
    static let plainRequirements: Set<String> = ["macos", "arch"]

    /// `curl` reads the catalog into the cache; `-z` turns a repeat download into a 304 when the
    /// catalog has not changed, and `-R` keeps the server's date on the file for that check.
    static func catalogCommand(cache: URL) -> ShellCommand {
        let conditional = FileManager.default.fileExists(atPath: cache.path) ? ["-z", cache.path] : []
        return ShellCommand("/usr/bin/curl", ["-fsSL", "--compressed", "-R", "--max-time", "120"] + conditional + ["-o", cache.path, catalogURL])
    }

    /// `~/Library/Caches/<bundle id>/cask.json`, its folder created on first use.
    static func cacheURL() throws -> URL {
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Nora", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cask.json")
    }

    static func feedCommand(_ feed: URL) -> ShellCommand {
        ShellCommand("/usr/bin/curl", ["-fsSL", "--max-time", "20", feed.absoluteString])
    }

    // MARK: - Local apps

    private struct InfoPlist: Decodable {
        let bundleID: String?
        let version: String?
        let build: String?
        let feed: String?

        enum CodingKeys: String, CodingKey {
            case bundleID = "CFBundleIdentifier", version = "CFBundleShortVersionString"
            case build = "CFBundleVersion", feed = "SUFeedURL"
        }
    }

    /// Reads an app bundle. Nil for App Store apps (they carry a receipt), Apple's own apps,
    /// `excluding` (Nora itself) and anything without a bundle ID or a version.
    static func local(path: String, name: String, excluding: String?) -> Local? {
        let contents = URL(fileURLWithPath: path).appendingPathComponent("Contents")
        guard !FileManager.default.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path),
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListDecoder().decode(InfoPlist.self, from: data),
              let bundleID = info.bundleID, !bundleID.isEmpty, !bundleID.hasPrefix("com.apple."), bundleID != excluding,
              let version = info.version ?? info.build, !version.isEmpty
        else { return nil }
        let feed = info.feed.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return Local(path: path, name: name, bundleID: bundleID, version: version, build: info.build, feed: feed,
                     movable: FileManager.default.isWritableFile(atPath: path))
    }

    // MARK: - Versions

    /// The digit runs of a version: "0.1.815-beta" is [0, 1, 815]. Empty when there are none or
    /// one is too long to be a version number.
    static func numbers(_ version: String) -> [Int] {
        var out: [Int] = []
        for run in version.split(whereSeparator: { !$0.isASCII || !$0.isNumber }) {
            guard let value = Int(run) else { return [] }
            out.append(value)
        }
        return out
    }

    /// The letters of a version, lowercased: "2.0rc1" has "rc", "0.1.815-beta" has "beta".
    static func tag(_ version: String) -> String {
        String(version.lowercased().filter { $0.isASCII && $0.isLetter })
    }

    /// True only when `latest` is strictly newer. A cask version's build after the comma
    /// ("5.8.1,2349") is ignored: builds are numbered differently from app to app. Versions with
    /// different letters do not compare: "2.0rc1" reads as 2.0.1 but is older than 2.0, so a
    /// beta, a release candidate or a hotfix is compared only with one of its own kind.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        let latest = String(latest.split(separator: ",", maxSplits: 1).first ?? "")
        guard tag(latest) == tag(installed) else { return false }
        let new = numbers(latest)
        let old = numbers(installed)
        guard !new.isEmpty, !old.isEmpty else { return false }
        let count = max(new.count, old.count)
        let a = new + Array(repeating: 0, count: count - new.count)
        let b = old + Array(repeating: 0, count: count - old.count)
        return b.lexicographicallyPrecedes(a)
    }

    // MARK: - Homebrew catalog

    /// Any JSON value. Kept only to collect a cask's strings.
    enum JSONValue: Decodable {
        case string(String), list([JSONValue]), object([String: JSONValue]), other

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s) }
            else if let l = try? c.decode([JSONValue].self) { self = .list(l) }
            else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
            else { self = .other }
        }

        var strings: [String] {
            switch self {
            case .string(let s): [s]
            case .list(let l): l.flatMap(\.strings)
            case .object(let o): o.values.flatMap(\.strings)
            case .other: []
            }
        }
    }

    private struct CatalogCask: Decodable {
        let token: String
        let version: String?
        let autoUpdates: Bool?
        let deprecated: Bool?
        let disabled: Bool?
        let artifacts: [[String: JSONValue]]?
        let dependsOn: [String: JSONValue]?

        enum CodingKeys: String, CodingKey {
            case token, version, deprecated, disabled, artifacts, autoUpdates = "auto_updates", dependsOn = "depends_on"
        }
    }

    /// The catalog without casks that cannot match: versioned variants (`@beta`), deprecated or
    /// disabled casks, `latest` versions and casks without an `app` artifact.
    static func parseCatalog(_ data: Data) throws -> [Cask] {
        try JSONDecoder().decode([CatalogCask].self, from: data).compactMap(cask)
    }

    private struct InfoRoot: Decodable { let casks: [CatalogCask]? }

    /// The cask as `brew info --cask --json=v2` describes it now, read like the catalog, so the
    /// same checks run again right before Nora changes anything.
    static func parseInfo(_ data: Data, token: String) throws -> Cask? {
        try JSONDecoder().decode(InfoRoot.self, from: data).casks?.compactMap(cask).first { $0.token == token }
    }

    private static func cask(_ cask: CatalogCask) -> Cask? {
        guard !cask.token.contains("@"), cask.deprecated != true, cask.disabled != true,
              let version = cask.version, version != "latest" else { return nil }
        let artifacts = cask.artifacts ?? []
        let apps = artifacts.compactMap { $0["app"] }.flatMap(appNames)
        guard !apps.isEmpty else { return nil }
        let keys = Set(artifacts.flatMap(\.keys))
        let requirements = Set((cask.dependsOn ?? [:]).keys)
        return Cask(token: cask.token, version: version, autoUpdates: cask.autoUpdates ?? false,
                    apps: apps, strings: artifacts.flatMap { $0.values.flatMap(\.strings) },
                    installsOnlyApp: keys.isSubset(of: appOnlyArtifacts) && requirements.isSubset(of: plainRequirements))
    }

    /// The names the `app` artifact installs. In `["A.app", {"target": "B.app"}]` the object renames
    /// the app before it: Homebrew installs B.app, and A.app never exists on disk. A target in
    /// another folder ("Tools/B.app", "~/Applications/B.app") is not in /Applications, so it gives
    /// no name at all.
    static func appNames(_ value: JSONValue) -> [String] {
        guard case .list(let entries) = value else { return [] }
        var names: [String?] = []
        for entry in entries {
            if case .string(let s) = entry { names.append((s as NSString).lastPathComponent) }
            if case .object(let o) = entry, case .string(let target)? = o["target"], !names.isEmpty {
                names[names.count - 1] = target.contains("/") ? nil : target
            }
        }
        return names.compactMap { $0 }
    }

    static func index(_ casks: [Cask]) -> [String: [Cask]] {
        var out: [String: [Cask]] = [:]
        for cask in casks { for app in Set(cask.apps) { out[app, default: []].append(cask) } }
        return out
    }

    /// The one cask whose `app` artifact installs this file name and whose artifacts name this
    /// exact bundle ID. None or several: no match.
    static func match(_ app: Local, in index: [String: [Cask]]) -> Cask? {
        let found = (index[app.fileName] ?? []).filter { cask in cask.strings.contains { names($0, bundleID: app.bundleID) } }
        return found.count == 1 ? found[0] : nil
    }

    /// True when `string` names exactly this bundle ID: the ID itself (a `quit` entry), or a path
    /// ending in the ID or the ID with a per-app extension (preferences, saved state, cookies).
    /// "com.example.editor.pro.plist" does not name "com.example.editor".
    static func names(_ string: String, bundleID: String) -> Bool {
        let last = (string as NSString).lastPathComponent
        return last == bundleID || ["plist", "savedState", "binarycookies"].contains { last == bundleID + "." + $0 }
    }

    /// The cask's version, when it is newer. Homebrew installs it only for an app in
    /// /Applications (Homebrew's app folder) that Nora can move aside, and a cask that installs
    /// nothing else.
    static func update(_ app: Local, cask: Cask, brewFound: Bool) -> Update? {
        guard isNewer(cask.version, than: app.version) else { return nil }
        let inAppFolder = (app.path as NSString).deletingLastPathComponent == "/Applications"
        return Update(path: app.path, name: app.name, bundleID: app.bundleID, installed: app.version,
                      latest: String(cask.version.split(separator: ",", maxSplits: 1).first ?? ""),
                      action: brewFound && inAppFolder && app.movable && cask.installsOnlyApp ? .brew(cask.token) : .open)
    }

    /// The app already has the update: it is now at least the version the review offered.
    static func updatedItself(_ item: Update, now current: Local) -> Bool {
        current.bundleID == item.bundleID && current.version != item.installed
            && !isNewer(item.latest, than: current.version) && isNewer(current.version, than: item.installed)
    }

    /// The app's own feed wins when it is ahead of the cask: Homebrew would install an older
    /// version than the one the app offers itself. A feed that has only build numbers does not
    /// compare with the cask's marketing version, so it wins too: Open is the safe choice.
    static func choose(feed: Update?, cask: Update?) -> Update? {
        guard let feed else { return cask }
        guard let cask, !feed.builds, !isNewer(feed.latest, than: cask.latest) else { return feed }
        return cask
    }

    // MARK: - Sparkle feed

    struct FeedItem: Hashable, Sendable {
        var shortVersion: String?
        var version: String?
        var minimumSystem: String?
        var channel: String?
    }

    /// The items of a Sparkle appcast. Versions come from the item's elements or its enclosure.
    static func parseFeed(_ data: Data) -> [FeedItem] {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        return parser.parse() ? reader.items : []
    }

    /// The newest item the user would get: no beta channel, and one this macOS can run.
    static func newest(_ items: [FeedItem], system: [Int]) -> FeedItem? {
        items.filter { item in
            item.channel == nil && (item.minimumSystem.map { !isNewer($0, than: system.map(String.init).joined(separator: ".")) } ?? true)
        }
        .max { a, b in isNewer(b.shortVersion ?? b.version ?? "", than: a.shortVersion ?? a.version ?? "") }
    }

    /// Compares like with like: the feed's marketing version with the app's, or, when the feed
    /// has only build numbers, its build with the app's build.
    static func update(_ app: Local, feed items: [FeedItem], system: [Int]) -> Update? {
        guard let item = newest(items, system: system) else { return nil }
        let pair: (String, String, Bool)? = if let short = item.shortVersion { (short, app.version, false) }
            else if let version = item.version, let build = app.build { (version, build, true) }
            else { nil }
        guard let (latest, installed, builds) = pair, isNewer(latest, than: installed) else { return nil }
        return Update(path: app.path, name: app.name, bundleID: app.bundleID, installed: installed, latest: latest,
                      action: .open, builds: builds)
    }

    private final class FeedReader: NSObject, XMLParserDelegate {
        var items: [FeedItem] = []
        private var current: FeedItem?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            if name == "item" { current = FeedItem() }
            if name == "enclosure", var item = current {
                item.shortVersion = item.shortVersion ?? attributes["sparkle:shortVersionString"]
                item.version = item.version ?? attributes["sparkle:version"]
                current = item
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "item": if let item = current { items.append(item) }; current = nil
            case "sparkle:shortVersionString": current?.shortVersion = value
            case "sparkle:version": current?.version = value
            case "sparkle:minimumSystemVersion": current?.minimumSystem = value
            case "sparkle:channel": current?.channel = value
            default: break
            }
            text = ""
        }
    }
}

extension OutsideApps {
    /// Old copies set aside while Homebrew installs their new version. An entry is written, and
    /// synced, before the move and cleared only once the new version is verified or the old copy
    /// is back. An entry left behind means Nora stopped mid-install (quit, crash, kill); `recover`
    /// then finishes the job: a verified new version keeps its place and the old copy goes to the
    /// Trash, anything else gives way to the old copy. A journal Nora cannot read or write stops
    /// a handover before it starts instead of being treated as empty.
    struct Journal: Sendable {
        struct Entry: Codable, Hashable, Sendable {
            let original: String
            /// Where the old copy waits. 1.1.0 wrote `trashed`, a path in the Trash.
            let staged: String
            /// The ID the new version must have; nil in entries from 1.1.0.
            var bundleID: String?

            init(original: String, staged: String, bundleID: String?) {
                self.original = original
                self.staged = staged
                self.bundleID = bundleID
            }

            enum CodingKeys: String, CodingKey { case original, staged, trashed, bundleID }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                original = try c.decode(String.self, forKey: .original)
                staged = try c.decodeIfPresent(String.self, forKey: .staged) ?? c.decode(String.self, forKey: .trashed)
                bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(original, forKey: .original)
                try c.encode(staged, forKey: .staged)
                try c.encodeIfPresent(bundleID, forKey: .bundleID)
            }
        }

        let url: URL
        /// Moves a file to the Trash; tests pass a plain folder instead.
        var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

        /// Where old copies wait: next to the journal, on the same volume as the home folder.
        var staging: URL { url.deletingLastPathComponent().appendingPathComponent("Handover", isDirectory: true) }

        func entries() throws -> [Entry] {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        }

        func add(_ entry: Entry) throws { try write(try entries().filter { $0 != entry } + [entry]) }
        func remove(_ entry: Entry) throws { try write(try entries().filter { $0 != entry }) }

        /// Finishes every handover a stop interrupted. Returns the paths whose old copy came back.
        @discardableResult
        func recover() -> [String] {
            guard let entries = try? entries() else { return [] }
            var restored: [String] = []
            for entry in entries {
                switch settle(entry) {
                case .restored: restored.append(entry.original); try? remove(entry)
                case .done: try? remove(entry)
                case .stuck: continue
                }
            }
            return restored
        }

        enum Settled { case restored, done, stuck }

        /// Brings one entry to rest. A verified new version keeps its place and the old copy goes
        /// to the Trash; otherwise whatever is in the app's place goes to the Trash and the old copy
        /// goes back. `verify: false` treats the place as failed, because the caller just checked it.
        func settle(_ entry: Entry, verify: Bool = true) -> Settled {
            let fm = FileManager.default
            let original = URL(fileURLWithPath: entry.original)
            let staged = URL(fileURLWithPath: entry.staged)
            guard fm.fileExists(atPath: staged.path) else { return .done }   // already back, or the Trash was emptied
            if verify, verified(entry) != nil {
                discard(staged)
                return fm.fileExists(atPath: staged.path) && owns(staged) ? .stuck : .done
            }
            if fm.fileExists(atPath: original.path) {
                guard (try? trash(original)) != nil else { return .stuck }
            }
            guard (try? fm.moveItem(at: staged, to: original)) != nil else { return .stuck }
            if owns(staged) { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
            return .restored
        }

        /// The app now in the entry's place, when it is a readable bundle with the expected ID.
        func verified(_ entry: Entry) -> Local? {
            let name = (entry.original as NSString).lastPathComponent
            guard let app = OutsideApps.local(path: entry.original, name: name, excluding: nil),
                  entry.bundleID.map({ $0 == app.bundleID }) ?? true else { return nil }
            return app
        }

        /// The old copy to the Trash, with its folder. A copy outside the staging folder, such as
        /// one 1.1.0 already put in the Trash, stays where it is.
        func discard(_ staged: URL) {
            guard owns(staged), (try? trash(staged)) != nil else { return }
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        }

        /// True for a copy in its own folder under `staging`, the only place Nora cleans up.
        private func owns(_ staged: URL) -> Bool {
            staged.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == staging.standardizedFileURL.path
        }

        private func write(_ entries: [Entry]) throws {
            if entries.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(entries)
                try data.write(to: url, options: .atomic)
                let handle = try FileHandle(forUpdating: url)
                try handle.synchronize()
                try handle.close()
            }
        }
    }

    /// One app handed over to Homebrew, as a transaction: journal, set the old copy aside, install,
    /// verify the new bundle, and only then put the old copy in the Trash. The install itself is a
    /// closure, so tests drive every step with plain folders.
    struct Handover {
        let journal: Journal

        enum Outcome: Equatable {
            /// The new version is in place, with this version string.
            case updated(String)
            /// Nothing changed: the journal could not be written or the app could not be moved.
            case untouched(String)
            /// The install failed or gave something else; the old copy is back in place.
            case restored
            /// The install failed and the old copy could not go back; it waits in `staged`, and
            /// the journal puts it back the next time Nora starts.
            case setAside(staged: String)
        }

        /// `expected` is the app as read right before this call; the new bundle must have its ID
        /// and must not be older.
        @MainActor func run(_ expected: Local, install: () async -> Void) async -> Outcome {
            let fm = FileManager.default
            let original = URL(fileURLWithPath: expected.path)
            let staged = journal.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(original.lastPathComponent)
            let entry = Journal.Entry(original: original.path, staged: staged.path, bundleID: expected.bundleID)
            do {
                try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                try journal.add(entry)
            } catch {
                return .untouched(error.localizedDescription)
            }
            do {
                try fm.moveItem(at: original, to: staged)
            } catch {
                try? journal.remove(entry)
                try? fm.removeItem(at: staged.deletingLastPathComponent())
                return .untouched(error.localizedDescription)
            }
            await install()
            if let new = journal.verified(entry), !OutsideApps.isNewer(expected.version, than: new.version) {
                journal.discard(staged)
                // A copy the Trash refused stays journaled; the next start retries.
                if !fm.fileExists(atPath: staged.path) { try? journal.remove(entry) }
                return .updated(new.version)
            }
            switch journal.settle(entry, verify: false) {
            case .restored: try? journal.remove(entry); return .restored
            case .done, .stuck: return .setAside(staged: staged.path)
            }
        }
    }
}
