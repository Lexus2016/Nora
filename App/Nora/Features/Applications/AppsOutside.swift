import Foundation
import MoleKit

/// Updates for apps installed outside Homebrew and the App Store, such as from a DMG. An app with
/// its own Sparkle feed (`SUFeedURL`) is checked against that feed; any other app against
/// Homebrew's public cask catalog. A cask counts only when the app's file name AND its bundle ID
/// both appear in it, so two apps that share a name (Telegram.app) never pick the wrong cask.
/// An update is reported only when the marketing version is strictly newer; anything that does
/// not read as a version is skipped. Parsing and matching are pure, so they are tested offline.
///
/// Updating: when the matched cask is newer and installs nothing but the app, Nora moves the old
/// copy to the Trash and runs `brew install --cask`, so from then on Homebrew updates the app.
/// Any other app gets Open: its own updater installs the new version.
enum OutsideApps {
    /// One installed app that neither Homebrew nor the App Store manages.
    struct Local: Hashable, Sendable {
        let path: String
        let name: String
        let bundleID: String
        let version: String
        let build: String?
        let feed: URL?
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
        return Local(path: path, name: name, bundleID: bundleID, version: version, build: info.build, feed: feed)
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

    /// True only when `latest` is strictly newer. A cask version's build after the comma
    /// ("5.8.1,2349") is ignored: builds are numbered differently from app to app.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        let new = numbers(String(latest.split(separator: ",", maxSplits: 1).first ?? ""))
        let old = numbers(installed)
        guard !new.isEmpty, !old.isEmpty else { return false }
        let count = max(new.count, old.count)
        let a = new + Array(repeating: 0, count: count - new.count)
        let b = old + Array(repeating: 0, count: count - old.count)
        return b.lexicographicallyPrecedes(a)
    }

    // MARK: - Homebrew catalog

    /// Any JSON value. Kept only to collect a cask's strings.
    private enum JSONValue: Decodable {
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
        try JSONDecoder().decode([CatalogCask].self, from: data).compactMap { cask in
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
    }

    /// `"app": ["A.app", {"target": "B.app"}]` gives the installed names A.app and B.app.
    private static func appNames(_ value: JSONValue) -> [String] {
        guard case .list(let entries) = value else { return [] }
        return entries.compactMap { entry in
            if case .string(let s) = entry { return (s as NSString).lastPathComponent }
            if case .object(let o) = entry, case .string(let target)? = o["target"] { return (target as NSString).lastPathComponent }
            return nil
        }
    }

    static func index(_ casks: [Cask]) -> [String: [Cask]] {
        var out: [String: [Cask]] = [:]
        for cask in casks { for app in Set(cask.apps) { out[app, default: []].append(cask) } }
        return out
    }

    /// The one cask whose `app` artifact has this file name and whose artifacts mention the
    /// bundle ID. None or several: no match.
    static func match(_ app: Local, in index: [String: [Cask]]) -> Cask? {
        let found = (index[app.fileName] ?? []).filter { cask in cask.strings.contains { $0.contains(app.bundleID) } }
        return found.count == 1 ? found[0] : nil
    }

    /// The cask's version, when it is newer. Homebrew installs it only for an app in
    /// /Applications (Homebrew's app folder) and a cask that installs nothing else.
    static func update(_ app: Local, cask: Cask, brewFound: Bool) -> Update? {
        guard isNewer(cask.version, than: app.version) else { return nil }
        let inAppFolder = (app.path as NSString).deletingLastPathComponent == "/Applications"
        return Update(path: app.path, name: app.name, bundleID: app.bundleID, installed: app.version,
                      latest: String(cask.version.split(separator: ",", maxSplits: 1).first ?? ""),
                      action: brewFound && inAppFolder && cask.installsOnlyApp ? .brew(cask.token) : .open)
    }

    /// The app's own feed wins when it is ahead of the cask: Homebrew would install an older
    /// version than the one the app offers itself.
    static func choose(feed: Update?, cask: Update?) -> Update? {
        guard let feed else { return cask }
        guard let cask, !isNewer(feed.latest, than: cask.latest) else { return feed }
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
        let pair: (String, String)? = if let short = item.shortVersion { (short, app.version) }
            else if let version = item.version, let build = app.build { (version, build) }
            else { nil }
        guard let (latest, installed) = pair, isNewer(latest, than: installed) else { return nil }
        return Update(path: app.path, name: app.name, bundleID: app.bundleID, installed: installed, latest: latest, action: .open)
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
