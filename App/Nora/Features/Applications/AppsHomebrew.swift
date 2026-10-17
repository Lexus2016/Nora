import Foundation
import MoleKit

/// Homebrew casks with a newer version. Reads go through `brew outdated` and `brew info`
/// (both read-only). The only write, `brew upgrade --cask`, runs when the user presses Update.
/// Parsing and command building are pure, so they are tested without running brew.
enum Homebrew {
    /// One outdated cask: `brew outdated` gives the versions, `brew info` the display name and
    /// whether the app updates itself.
    struct Update: Identifiable, Hashable, Sendable {
        let token: String
        let name: String
        let installed: String
        let latest: String
        let autoUpdates: Bool
        /// The `.app` bundles the cask installs, by file name; an open one is quit before the upgrade.
        var apps: [String] = []
        var id: String { token }
    }

    struct Outdated: Hashable, Sendable {
        let token: String
        let installed: String
        let latest: String
    }

    struct CaskInfo: Hashable, Sendable {
        let name: String?
        let autoUpdates: Bool
        var apps: [String] = []
    }

    /// Homebrew's app folder: where `brew` puts a cask's `.app`.
    static let appDirectory = "/Applications"

    static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// No auto-update, so the list the user reviewed is the list that gets upgraded; no analytics.
    static let variables = ["HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_AUTO_UPDATE": "1"]

    static func executable() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// ProcessRunner replaces the whole environment, so PATH and HOME are kept here.
    static var processEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging(variables) { $1 }
    }

    static func outdatedArguments() -> [String] { ["outdated", "--cask", "--greedy", "--json=v2"] }
    static func infoArguments() -> [String] { ["info", "--cask", "--json=v2", "--installed"] }

    /// The command as the console and the review footer show it, variables included.
    static func command(_ executable: String, _ arguments: [String]) -> ShellCommand {
        ShellCommand(executable, arguments, environment: variables)
    }

    /// `brew upgrade --cask <tokens>`. Refused when the list is empty or a token would be read
    /// as a flag or contains control characters. Other tokens are one argument each; the
    /// display quotes any that need it.
    static func upgradeCommand(tokens: [String], executable: String) -> ShellCommand? {
        guard !tokens.isEmpty, tokens.allSatisfy(isValidToken) else { return nil }
        return command(executable, ["upgrade", "--cask"] + tokens)
    }

    /// `brew install --cask <token>` for an app Nora found outside Homebrew; same token rules.
    static func installCommand(token: String, executable: String) -> ShellCommand? {
        guard isValidToken(token) else { return nil }
        return command(executable, ["install", "--cask", token])
    }

    /// `brew info` for one cask: the version Homebrew would install now. With auto-update off it
    /// can be older than the public catalog the scan read.
    static func infoArguments(token: String) -> [String] { ["info", "--cask", "--json=v2", token] }

    /// Where brew keeps its record of an installed cask: `<prefix>/Caskroom/<token>`, the prefix
    /// taken from the brew path as given (on Intel `/usr/local/bin/brew` resolves into
    /// `/usr/local/Homebrew`, but the Caskroom is `/usr/local/Caskroom`). Nil without a Caskroom.
    static func caskRecord(token: String, executable: String) -> URL? {
        guard isValidToken(token), !token.contains("/") else { return nil }
        let caskroom = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Caskroom", isDirectory: true)
        guard FileManager.default.fileExists(atPath: caskroom.path) else { return nil }
        return caskroom.appendingPathComponent(token, isDirectory: true)
    }

    /// Makes brew forget a cask it recorded during a failed handover, without `brew uninstall`:
    /// that would run the cask's uninstall steps (quit, launchctl, delete) against the old copy
    /// Nora just put back. Only a record that did not exist before goes, to the Trash. True when
    /// it went.
    static func forget(_ record: URL, recordedBefore: Bool,
                       trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Bool {
        guard !recordedBefore, FileManager.default.fileExists(atPath: record.path) else { return false }
        return (try? trash(record)) != nil
    }

    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && !token.hasPrefix("-")
            && !token.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    // MARK: - JSON (required v2 envelopes; optional display metadata may be absent)

    private struct OutdatedRoot: Decodable {
        let casks: [OutdatedCask]
    }

    /// `name` is the cask token here, not the display name.
    private struct OutdatedCask: Decodable {
        let name: String
        let installedVersions: [String]?
        let currentVersion: String?

        enum CodingKeys: String, CodingKey {
            case name, installedVersions = "installed_versions", currentVersion = "current_version"
        }
    }

    private struct InfoRoot: Decodable {
        let casks: [InfoCask]
    }

    private struct InfoCask: Decodable {
        let token: String
        let name: [String]?
        let autoUpdates: Bool?
        let apps: [String]

        enum CodingKeys: String, CodingKey {
            case token, name, artifacts, autoUpdates = "auto_updates"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            name = try? c.decode([String].self, forKey: .name)
            autoUpdates = try? c.decode(Bool.self, forKey: .autoUpdates)
            // Lenient: a cask whose artifacts do not read still lists its update, just without apps.
            let artifacts = (try? c.decode([[String: OutsideApps.JSONValue]].self, forKey: .artifacts)) ?? []
            apps = artifacts.compactMap { $0["app"] }.flatMap(OutsideApps.appNames)
        }
    }

    static func parseOutdated(_ data: Data) throws -> [Outdated] {
        let root = try JSONDecoder().decode(OutdatedRoot.self, from: data)
        guard Set(root.casks.map(\.name)).count == root.casks.count,
              root.casks.allSatisfy({ isValidToken($0.name) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid or duplicate cask token"))
        }
        return root.casks.map {
            Outdated(token: $0.name,
                     installed: ($0.installedVersions ?? []).joined(separator: ", "),
                     latest: $0.currentVersion ?? "?")
        }
    }

    static func parseInfo(_ data: Data) throws -> [String: CaskInfo] {
        let root = try JSONDecoder().decode(InfoRoot.self, from: data)
        var out: [String: CaskInfo] = [:]
        for cask in root.casks {
            out[cask.token] = CaskInfo(name: cask.name?.first, autoUpdates: cask.autoUpdates ?? false, apps: cask.apps)
        }
        return out
    }

    /// Joins the two outputs. Without a display name the token is shown; sorted by name.
    static func merge(outdated: [Outdated], info: [String: CaskInfo]) -> [Update] {
        outdated.map { item in
            let meta = info[item.token]
            return Update(token: item.token,
                          name: meta?.name ?? item.token,
                          installed: item.installed,
                          latest: item.latest,
                          autoUpdates: meta?.autoUpdates ?? false,
                          apps: meta?.apps ?? [])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
