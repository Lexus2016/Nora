import MoleKit
import Observation
import SwiftUI

/// Applications. The scan (`mo uninstall --list`, bundle sizes, last-used dates, Homebrew cask
/// updates and updates for apps from a download) leads to results and to three places: the full
/// app list, the updates, and uninstalling. Uninstalling is unchanged: each app's plan comes from `mo uninstall --dry-run`,
/// and the driver answers only when Mole's plan matches it. Apps go to the Trash by default.
@MainActor @Observable
final class AppsModel {
    struct Plan: Identifiable {
        let app: InstalledApp
        var entries: [String] = []
        var error: String?
        var id: String { app.id }
    }

    /// What the review stage shows. `stage` is `.review` for all of them.
    enum Screen: Equatable { case results, list, updates, plans }
    enum ListFilter: Equatable { case all, unused }

    var stage: FlowStage = .start
    var screen: Screen = .results
    var listFilter: ListFilter = .all
    var apps: [InstalledApp] = []
    var sizes: [String: Int64] = [:]
    var lastUsed: [String: Date] = [:]
    var unusedPaths: Set<String> = []
    var brewFound = false
    var updates: [Homebrew.Update] = []
    /// Apps installed outside Homebrew and the App Store that have a newer version.
    var outside: [OutsideApps.Update] = []
    /// Why the updates are missing: Homebrew not found, or its check failed.
    var updatesNote: String?
    var selected: Set<String> = []
    /// Cask tokens of Homebrew apps and paths of apps from a download. A path starts with "/",
    /// a token never does.
    var selectedUpdates: Set<String> = []
    var search = ""
    var plans: [Plan] = []
    var permanent = false
    var error: String?
    var scanTitle = "Looking at your apps…"
    var scanStep = ""
    var runningUpdates = false
    /// The updates are done and the apps Nora quit are opening again (a few seconds each).
    var reopening = false
    /// Selected apps that were open when Update was pressed. The question names them, and only
    /// these paths may be quit; an app opened later is skipped, not closed.
    var openToQuit: [(name: String, path: String)] = []
    /// The question is on screen. Kept apart from `openToQuit`, so dismissing the alert never
    /// empties the list before "Quit and update" has read it.
    var askingToQuit = false
    /// Stop was pressed during removal or updates: the app in progress finishes, the rest wait.
    /// Cutting `mo uninstall` or `brew upgrade` short could leave an app half removed.
    var stopRequested = false
    var resultHeadline = ""
    var resultLines: [String] = []
    var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The list: all apps (largest first), or only the unused ones; search applies to both.
    var visible: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var base = listFilter == .unused ? apps.filter { unusedPaths.contains($0.path) } : apps
        if !q.isEmpty {
            base = base.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(q) }
        }
        return bySize(base)
    }

    var unusedApps: [InstalledApp] { bySize(apps.filter { unusedPaths.contains($0.path) }) }
    var largestApps: [InstalledApp] { bySize(apps) }
    var chosen: [InstalledApp] { apps.filter { selected.contains($0.path) } }
    var selectedSize: Int64 { chosen.reduce(0) { $0 + (sizes[$1.path] ?? 0) } }
    var selectedTokens: [String] { updates.map(\.token).filter { selectedUpdates.contains($0) } }
    var selectedOutside: [OutsideApps.Update] { outside.filter { $0.token != nil && selectedUpdates.contains($0.path) } }
    /// Everything Update can install: Homebrew apps, and apps from a download Homebrew can take over.
    var updatableIDs: [String] { updates.map(\.token) + outside.filter { $0.token != nil }.map(\.path) }
    var updateCount: Int { updates.count + outside.count }

    /// Where each selected update's app lives, with the name the result lines use.
    private func bundles(of update: Homebrew.Update) -> [String] {
        update.apps.map { Homebrew.appDirectory + "/" + $0 }
    }

    private func bySize(_ list: [InstalledApp]) -> [InstalledApp] {
        list.sorted { (sizes[$0.path] ?? -1) > (sizes[$1.path] ?? -1) }
    }

    /// Every command the scan runs, for the start screen.
    var scanCommand: String {
        var parts = ["mo uninstall --list"]
        if let path = Homebrew.executable() {
            parts.append(Homebrew.command(path, Homebrew.outdatedArguments()).description)
            parts.append(Homebrew.command(path, Homebrew.infoArguments()).description)
        }
        // A command preview must not create a cache directory merely by rendering the view.
        if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cache = folder.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Nora", isDirectory: true)
                .appendingPathComponent("cask.json")
            parts.append(OutsideApps.catalogCommand(cache: cache).description)
        }
        parts.append("curl -fsSL --max-time 20 <SUFeedURL>")
        return parts.joined(separator: "; ")
    }

    // MARK: - Scan

    func scan(_ app: AppModel) {
        error = nil
        scanTitle = "Looking at your apps…"
        scanStep = String(localized: "Listing apps")
        sizes = [:]
        lastUsed = [:]
        stage = .scanning
        task = Task(.applications) {
            do {
                let listed = try await app.run(["uninstall", "--list"])
                guard listed.succeeded, let data = listed.stdout.data(using: .utf8) else {
                    throw NoraError.commandFailed(listed.stderr.isEmpty ? listed.stdout : listed.stderr)
                }
                apps = try InstalledApp.decodeList(data)
                scanStep = String(localized: "Measuring sizes and last use")
                await inspect()
                try Task.checkCancellation()
                scanStep = String(localized: "Checking for updates")
                await checkUpdates(app)
                try Task.checkCancellation()
                await checkOutside(app)
                try Task.checkCancellation()
                let now = Date()
                unusedPaths = Set(apps.filter { AppUsage.isUnused(lastUsed: lastUsed[$0.path], now: now) }.map(\.path))
                selected = selected.intersection(apps.map(\.path))
                screen = .results
                stage = .review
            } catch is CancellationError {
                stage = .start
            } catch {
                self.error = error.localizedDescription
                stage = .start
            }
        }
    }

    /// Sizes and last-used dates, eight bundles at a time, off the main thread. Each bundle's
    /// date is read before its size walk.
    private func inspect() async {
        let paths = apps.map(\.path)
        for chunk in stride(from: 0, to: paths.count, by: 8).map({ Array(paths[$0..<min($0 + 8, paths.count)]) }) {
            let measured = await withTaskGroup(of: (String, Int64, Date?).self) { group in
                for path in chunk {
                    group.addTask {
                        let used = AppUsage.lastUsed(path: path)
                        return (path, AppUsage.allocatedSize(path), used)
                    }
                }
                var out: [(String, Int64, Date?)] = []
                for await item in group { out.append(item) }
                return out
            }
            for (path, size, used) in measured {
                sizes[path] = size
                lastUsed[path] = used
            }
            if Task.isCancelled { return }
        }
    }

    private func checkUpdates(_ app: AppModel) async {
        updates = []
        updatesNote = nil
        selectedUpdates = []
        guard let path = Homebrew.executable() else {
            brewFound = false
            updatesNote = String(localized: "Homebrew is not installed. Open an app to let it install its update.")
            return
        }
        brewFound = true
        do {
            updates = try await loadUpdates(app, path)
        } catch {
            if Task.isCancelled { return }
            updatesNote = String(localized: "Homebrew check failed. See the console.")
        }
    }

    private func loadUpdates(_ app: AppModel, _ path: String) async throws -> [Homebrew.Update] {
        let outdated = try Homebrew.parseOutdated(try await brew(app, path, Homebrew.outdatedArguments()))
        guard !outdated.isEmpty else { return [] }
        let info = try Homebrew.parseInfo(try await brew(app, path, Homebrew.infoArguments()))
        return Homebrew.merge(outdated: outdated, info: info)
    }

    /// Apps outside Homebrew and the App Store: each one's own update feed, and Homebrew's public
    /// catalog. When the download fails, the catalog from the last scan is used; with neither,
    /// these apps are simply not listed.
    private func checkOutside(_ app: AppModel) async {
        outside = []
        let me = Bundle.main.bundleIdentifier
        let candidates = apps.filter { $0.source != "Homebrew" }
        let locals = await Task.detached {
            candidates.compactMap { OutsideApps.local(path: $0.path, name: $0.name, excluding: me) }
        }.value
        guard !locals.isEmpty else { return }
        let index = await loadCatalog(app)
        let feeds = await loadFeeds(app, locals)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let system = [os.majorVersion, os.minorVersion, os.patchVersion]
        let brew = brewFound
        outside = locals.compactMap { local in
            let cask = OutsideApps.match(local, in: index).flatMap { OutsideApps.update(local, cask: $0, brewFound: brew) }
            let feed = feeds[local.path].flatMap { OutsideApps.update(local, feed: $0, system: system) }
            return OutsideApps.choose(feed: feed, cask: cask)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func loadCatalog(_ app: AppModel) async -> [String: [OutsideApps.Cask]] {
        guard let cache = try? OutsideApps.cacheURL() else { return [:] }
        _ = try? await read(app, OutsideApps.catalogCommand(cache: cache), environment: ProcessInfo.processInfo.environment)
        let casks = await Task.detached { (try? Data(contentsOf: cache)).flatMap { try? OutsideApps.parseCatalog($0) } ?? [] }.value
        return OutsideApps.index(casks)
    }

    /// Every app's feed at once; a feed that fails or does not parse just gives no update.
    private func loadFeeds(_ app: AppModel, _ locals: [OutsideApps.Local]) async -> [String: [OutsideApps.FeedItem]] {
        let environment = ProcessInfo.processInfo.environment
        return await withTaskGroup(of: (String, [OutsideApps.FeedItem]).self) { group in
            for local in locals {
                guard let feed = local.feed else { continue }
                group.addTask {
                    let data = try? await self.read(app, OutsideApps.feedCommand(feed), environment: environment)
                    return (local.path, data.map(OutsideApps.parseFeed) ?? [])
                }
            }
            var out: [String: [OutsideApps.FeedItem]] = [:]
            for await (path, items) in group { out[path] = items }
            return out
        }
    }

    private func brew(_ app: AppModel, _ path: String, _ arguments: [String]) async throws -> Data {
        try await read(app, Homebrew.command(path, arguments), environment: Homebrew.processEnvironment)
    }

    /// One read-only command, logged to the console with its exit status.
    private func read(_ app: AppModel, _ command: ShellCommand, environment: [String: String]) async throws -> Data {
        let id = app.console.begin(command)
        do {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: command.executable), command.arguments, environment: environment)
            if !result.stderr.isEmpty { app.console.append(id, result.stderr.components(separatedBy: "\n")) }
            app.console.finish(id, status: result.status)
            guard result.succeeded else { throw NoraError.commandFailed(result.stderr.isEmpty ? "\(command.executable) exited with status \(result.status)" : result.stderr) }
            return Data(result.stdout.utf8)
        } catch {
            app.console.fail(id, error: error)
            throw error
        }
    }

    // MARK: - Updates

    /// Update: asks first when a selected app is open, otherwise starts right away.
    func requestUpgrade(_ app: AppModel) {
        let brewOpen = updates.filter { selectedTokens.contains($0.token) }
            .flatMap { update in bundles(of: update).map { (name: update.name, path: $0) } }
        let otherOpen = selectedOutside.map { (name: $0.name, path: $0.path) }
        let open = (brewOpen + otherOpen).filter { OpenApps.running(at: $0.path) != nil }
        if open.isEmpty { upgrade(app) } else { openToQuit = open; askingToQuit = true }
    }

    /// Why an update was skipped before it started.
    enum QuitBlock { case stayedOpen, openedLater }

    /// Quits the open apps among `paths` right before their update, but only those the user agreed
    /// to quit. Returns the paths it quit, which open again at the end even when the update is
    /// skipped, and what stops the update, if anything.
    private func quitBeforeUpdate(_ paths: [String], approved: Set<String>) async -> (quit: [String], block: QuitBlock?) {
        await Self.quit(paths, approved: approved, isOpen: { OpenApps.running(at: $0) != nil }, quit: { path in
            guard let running = OpenApps.running(at: path) else { return true }
            return await OpenApps.quit(running)
        })
    }

    static func quit(_ paths: [String], approved: Set<String>, isOpen: (String) -> Bool,
                     quit: (String) async -> Bool) async -> (quit: [String], block: QuitBlock?) {
        var closed: [String] = []
        for path in paths where isOpen(path) {
            guard approved.contains(path) else { return (closed, .openedLater) }
            guard await quit(path) else { return (closed, .stayedOpen) }
            closed.append(path)
        }
        return (closed, nil)
    }

    private static func skipped(_ name: String, _ block: QuitBlock) -> String {
        switch block {
        case .stayedOpen: "✕ " + String(localized: "\(name): it stayed open, so it was not updated.")
        case .openedLater: "✕ " + String(localized: "\(name): it was opened during the update, so Nora left it open and did not update it.")
        }
    }

    /// Runs `brew upgrade --cask` for each selected cask in turn, so Stop can wait for the one in
    /// progress, then checks with `brew outdated` which of them are still behind. That check
    /// decides the result, because the upgrade's exit status does not say which cask failed.
    /// Selected apps from a download follow, one at a time (see `replace`).
    func upgrade(_ app: AppModel) {
        guard !app.trash.blocksOtherMutations else { updatesNote = AppModel.trashBusyMessage; askingToQuit = false; return }
        guard let path = Homebrew.executable() else { return }
        let tokens = selectedTokens
        let commands = tokens.compactMap { Homebrew.upgradeCommand(tokens: [$0], executable: path) }
        let others = selectedOutside
        guard commands.count == tokens.count, !(tokens.isEmpty && others.isEmpty) else { return }
        let approved = Set(openToQuit.map(\.path))
        openToQuit = []
        askingToQuit = false
        runningUpdates = true
        stopRequested = false
        stage = .running
        let brewBundles = Dictionary(uniqueKeysWithValues: updates.map { ($0.token, bundles(of: $0)) })
        task = Task(.applications) {
            var skipped: [String] = []
            var blocked: [String: QuitBlock] = [:]
            var reopen: [String] = []
            var attempted: Set<String> = []
            for (token, command) in zip(tokens, commands) {
                if stopRequested { skipped.append(token); continue }
                let (quit, block) = await quitBeforeUpdate(brewBundles[token] ?? [], approved: approved)
                reopen += quit
                if let block { blocked[token] = block; continue }
                attempted.insert(token)
                // A failed upgrade is in the console with its status; the check below reports it.
                try? await app.stream(command, environment: Homebrew.processEnvironment)
            }
            var done: [String] = []
            var lines: [String] = []
            var checked = true
            if !tokens.isEmpty {
                if let remaining = try? Set(Homebrew.parseOutdated(try await brew(app, path, Homebrew.outdatedArguments())).map(\.token)) {
                    done = tokens.filter { attempted.contains($0) && !remaining.contains($0) }
                    lines = done.map { "✓ \($0)" }
                        + tokens.compactMap { token in blocked[token].map { Self.skipped(token, $0) } }
                        + tokens.filter { remaining.contains($0) && !skipped.contains($0) && blocked[$0] == nil }.map { "✕ " + String(localized: "\($0) is still outdated") }
                        + skipped.map { "– " + String(localized: "\($0): not started, you pressed Stop") }
                    updates.removeAll { done.contains($0.token) }
                } else {
                    checked = false
                    lines = [String(localized: "Homebrew did not answer the check. See the console.")]
                }
            }
            for item in others {
                if stopRequested {
                    lines.append("– " + String(localized: "\(item.name): not started, you pressed Stop"))
                    continue
                }
                let (quit, block) = await quitBeforeUpdate([item.path], approved: approved)
                reopen += quit
                if let block { lines.append(Self.skipped(item.name, block)); continue }
                switch await replace(app, item, brew: path) {
                case .failed(let problem):
                    lines.append("✕ \(item.name): \(problem)")
                case .updated(let version):
                    done.append(item.path)
                    lines.append("✓ \(item.name) \(version)")
                    outside.removeAll { $0.path == item.path }
                }
            }
            // Every app Nora quit comes back, updated or not, each once.
            var seen = Set<String>()
            reopening = !reopen.isEmpty
            for bundle in reopen where seen.insert(bundle).inserted { await OpenApps.reopen(bundle) }
            reopening = false
            let total = tokens.count + others.count
            failed = !checked || done.count < total
            resultHeadline = !checked && done.isEmpty ? String(localized: "Could not check the result")
                : done.isEmpty ? String(localized: "No app was updated")
                : !failed ? String(localized: "\(done.count) apps updated")
                : String(localized: "Updated: \(done.count) of \(total)")
            resultLines = lines
            selectedUpdates = []
            runningUpdates = false
            stage = .done
        }
    }

    private enum Replaced { case updated(String), failed(String) }

    /// Hands an app from a download over to Homebrew. Right before anything changes, the app and
    /// the cask are read again: the bundle ID and version must be those of the review, and the cask
    /// must still install this file name, name this bundle ID, install nothing else and be newer.
    /// `Handover` then sets the old copy aside, installs, verifies the new bundle and puts the old
    /// copy back if anything is off. Returns the version now installed, or what went wrong.
    private func replace(_ app: AppModel, _ item: OutsideApps.Update, brew path: String) async -> Replaced {
        guard let token = item.token, let install = Homebrew.installCommand(token: token, executable: path) else {
            return .failed(String(localized: "Homebrew cannot install this app."))
        }
        guard let current = OutsideApps.local(path: item.path, name: item.name, excluding: nil), current.bundleID == item.bundleID else {
            return .failed(String(localized: "It changed since the scan. Scan again."))
        }
        // Many apps install a downloaded update as they quit (Sparkle, Squirrel's ShipIt): the
        // quit before this one may already have brought the new version.
        if OutsideApps.updatedItself(item, now: current), OutsideApps.hasExecutable(at: item.path) { return .updated(current.version) }
        guard current.version == item.installed else {
            return .failed(String(localized: "It changed since the scan. Scan again."))
        }
        guard let data = try? await brew(app, path, Homebrew.infoArguments(token: token)),
              let cask = try? OutsideApps.parseInfo(data, token: token),
              OutsideApps.match(current, in: OutsideApps.index([cask]))?.token == token, cask.installsOnlyApp else {
            return .failed(String(localized: "Homebrew no longer describes this app the way the scan saw it. Scan again."))
        }
        guard OutsideApps.isNewer(cask.version, than: current.version),
              OutsideApps.meetsTarget(String(cask.version.split(separator: ",", maxSplits: 1).first ?? ""), target: item.latest) else {
            return .failed(String(localized: "Homebrew's app list has no newer version yet. Run brew update and try again."))
        }
        // Checked after the last wait: an app reopened meanwhile (by the user or a login item) stays.
        if OpenApps.running(at: item.path) != nil {
            return .failed(String(localized: "It is running. Quit it and try again."))
        }
        let record = Homebrew.caskRecord(token: token, executable: path)
        let recorded = record.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        switch await OutsideApps.Handover(journal: app.handover).run(current, targetVersion: cask.version, install: {
            try? await app.stream(install, environment: Homebrew.processEnvironment)
        }) {
        case .updated(let version):
            return .updated(version)
        case .untouched(let reason):
            return .failed(String(localized: "Nothing was changed: \(reason)"))
        case .restored:
            // brew may have recorded the cask although Nora put the old copy back; a later
            // `brew upgrade` would then replace it. Its record goes, unless it was there before.
            if let record, Homebrew.forget(record, recordedBefore: recorded) {
                return .failed(String(localized: "Homebrew did not install a working new version. The old version is back in place, and Homebrew no longer lists the app."))
            }
            return .failed(String(localized: "Homebrew did not install a working new version. The old version is back in place."))
        case .setAside(let staged):
            return .failed(String(localized: "Homebrew did not install a working new version, and the old version could not go back yet. It is kept in \((staged as NSString).abbreviatingWithTildeInPath); Nora puts it back the next time it starts."))
        }
    }

    // MARK: - Uninstall

    func review(_ app: AppModel) {
        plans = chosen.map { Plan(app: $0) }
        scanTitle = "Finding every file…"
        scanStep = String(localized: "Reading Mole's removal plan")
        stage = .scanning
        task = Task(.applications) {
            for index in plans.indices {
                // Stop means stop: back to the list, no half-made review.
                guard !Task.isCancelled else { break }
                let target = plans[index].app
                do {
                    let (entries, _) = try await app.drive(["uninstall", "--dry-run", target.uninstallName]) { session in
                        try UninstallDriver().preview(app: target.name, in: session)
                    }
                    plans[index].entries = entries
                } catch is CancellationError {
                    break
                } catch {
                    plans[index].error = Self.describe(error)
                }
            }
            if Task.isCancelled {
                plans = []
                screen = .list
                stage = .review
                return
            }
            screen = .plans
            stage = .review
        }
    }

    /// What the removal runs, one command per app, as the review footers show it.
    func uninstallCommand(for apps: [InstalledApp]) -> String {
        apps.map { item in
            let admin = !FileManager.default.isDeletableFile(atPath: item.path)
            let args = ["uninstall", item.uninstallName] + (permanent ? ["--permanent"] : [])
            return (admin ? "sudo -A -v && " : "") + ShellCommand("mo", args).description
        }
        .joined(separator: "; ")
    }

    /// Absence must be observed, not inferred from exit 0 or an unreadable parent folder.
    /// Reading attributes also sees dangling symlinks, unlike `fileExists`.
    nonisolated static func removalPathIsAbsent(_ path: String) -> Bool {
        removalPathIsAbsent(path, attributes: { try FileManager.default.attributesOfItem(atPath: $0) })
    }

    nonisolated static func removalPathIsAbsent(_ path: String,
                                                attributes: (String) throws -> [FileAttributeKey: Any]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        do {
            _ = try attributes(path)
            return false
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue].contains(error.code)
        }
    }

    nonisolated static func remainingRemovalPaths(appPath: String, entries: [String],
                                      isAbsent: (String) -> Bool = AppsModel.removalPathIsAbsent) -> [String] {
        let paths = Set(([appPath] + entries).map { ($0 as NSString).expandingTildeInPath })
        return paths.filter { !isAbsent($0) }.sorted()
    }

    func uninstall(_ app: AppModel) {
        guard stage == .review, screen == .plans, !plans.isEmpty else { return }
        let ready = plans.filter { $0.error == nil && !$0.entries.isEmpty }
        runningUpdates = false
        stopRequested = false
        stage = .running
        task = Task(.applications) {
            var removed: [String] = [], removedPaths: Set<String> = [], problems: [String] = [], skipped: [String] = []
            for plan in ready {
                if stopRequested { skipped.append(plan.app.name); continue }
                let args = ["uninstall", plan.app.uninstallName] + (permanent ? ["--permanent"] : [])
                let needsAdmin = !FileManager.default.isDeletableFile(atPath: plan.app.path)
                do {
                    let expected = Set(plan.entries)
                    let (_, result) = try await app.drive(args, sudo: needsAdmin) { session in
                        try UninstallDriver().uninstall(app: plan.app.name, expectedEntries: expected, in: session)
                    }
                    let remaining = Self.remainingRemovalPaths(appPath: plan.app.path, entries: plan.entries)
                    // Keep the app list truthful even if the bundle went but some helpers remain.
                    if Self.removalPathIsAbsent(plan.app.path) { removedPaths.insert(plan.app.path) }
                    if result.succeeded && remaining.isEmpty {
                        removed.append(plan.app.name)
                    } else if !remaining.isEmpty {
                        problems.append(String(localized: "\(plan.app.name): removal could not be verified for \(remaining.joined(separator: ", "))."))
                    } else {
                        problems.append(plan.app.name)
                    }
                } catch {
                    if Self.removalPathIsAbsent(plan.app.path) { removedPaths.insert(plan.app.path) }
                    problems.append("\(plan.app.name): \(Self.describe(error))")
                }
            }
            // Apps whose plan could not be read were not touched; they still belong in the report.
            for plan in plans where plan.error != nil || plan.entries.isEmpty {
                problems.append("\(plan.app.name): \(plan.error ?? String(localized: "Mole found nothing to remove."))")
            }
            apps.removeAll { removedPaths.contains($0.path) }
            unusedPaths.subtract(removedPaths)
            failed = !problems.isEmpty || !skipped.isEmpty
            resultHeadline = failed ? String(localized: "Removal needs attention")
                : removed.isEmpty ? String(localized: "No app was removed")
                : String(localized: "\(removed.count) apps removed")
            resultLines = removed.map { "✓ \($0)" } + problems.map { "✕ \($0)" }
                + skipped.map { "– " + String(localized: "\($0): not started, you pressed Stop") }
            selected = []
            plans = []
            stage = .done
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case UninstallDriverError.matchMismatch(_, let onScreen):
            String(localized: "Mole matched a different app (\(onScreen.joined(separator: ", "))). Nothing was removed.")
        case UninstallDriverError.planMismatch:
            String(localized: "Mole's removal plan changed since the preview. Nothing was removed.")
        case UninstallDriverError.unreadablePlan:
            String(localized: "Nora could not read Mole's full removal plan. Nothing was removed.")
        default:
            error.localizedDescription
        }
    }

    // MARK: - Navigation

    func openList(_ filter: ListFilter) {
        listFilter = filter
        screen = .list
    }

    func cancelQuit() { openToQuit = []; askingToQuit = false }

    func openUpdates(all: Bool) {
        selectedUpdates = all ? Set(updatableIDs) : []
        screen = .updates
    }

    func stop() { task?.cancel() }

    /// Stop during removal or updates: the app in progress finishes, the rest are not started.
    func stopAfterCurrent() { stopRequested = true }

    /// One step back inside the review stage; from the results it returns to the start screen.
    func back() {
        switch screen {
        case .plans:
            plans = []
            screen = .list
        case .list, .updates:
            screen = .results
        case .results:
            reset()
        }
    }

    func reset() {
        plans = []
        selected = []
        selectedUpdates = []
        screen = .results
        error = nil
        stage = .start
    }
}

struct ApplicationsView: View {
    @Environment(AppModel.self) private var app
    private var model: AppsModel { app.apps }
    private let module = Module.applications

    var body: some View {
        switch model.stage {
        case .start:
            start.task { if app.autoScan { model.scan(app) } }
        case .scanning:
            WorkingView(module: module, title: LocalizedStringKey(model.scanTitle), detail: model.scanStep, onStop: { model.stop() })
        case .review:
            switch model.screen {
            case .results: AppsResults(model: model)
            case .list: AppsList(model: model)
            case .updates: AppsUpdates(model: model)
            case .plans: AppsReview(model: model)
            }
        case .running:
            WorkingView(module: module,
                        title: model.reopening ? "Opening the apps again…" : model.stopRequested ? "Finishing the current app…"
                            : model.runningUpdates ? "Updating apps…" : "Removing apps…",
                        detail: model.reopening ? nil : WorkingView.currentItem(app.console.output(of: module)),
                        onStop: model.stopRequested || model.reopening ? nil : { model.stopAfterCurrent() })
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) {
                model.reset()
            }
        }
    }

    private var start: some View {
        ModuleStart(module: module,
                    subtitle: "Remove an app with its helpers, caches and settings, update your apps, and find the ones you no longer open.",
                    features: [Feature(symbol: "xmark.app", text: "Uninstaller"),
                               Feature(symbol: "arrow.triangle.2.circlepath", text: "Updates"),
                               Feature(symbol: "moon.zzz", text: "Unused apps"),
                               Feature(symbol: "chart.bar", text: "Largest apps")],
                    command: model.scanCommand,
                    action: { model.scan(app) }) {
            if let error = model.error { Notice(text: error, color: Palette.crit) }
        }
    }
}

enum ShellQuote {
    static func word(_ s: String) -> String { ShellCommand("", [s]).description.trimmingCharacters(in: .whitespaces) }
}
