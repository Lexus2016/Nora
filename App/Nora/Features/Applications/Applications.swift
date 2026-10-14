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
    /// Names of selected apps that are open: Update asks before it quits them.
    var openToQuit: [String] = []
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
        if let cache = try? OutsideApps.cacheURL() { parts.append(OutsideApps.catalogCommand(cache: cache).description) }
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
        let brewOpen = updates.filter { selectedTokens.contains($0.token) && bundles(of: $0).contains { OpenApps.running(at: $0) != nil } }.map(\.name)
        let otherOpen = selectedOutside.filter { OpenApps.running(at: $0.path) != nil }.map(\.name)
        let open = brewOpen + otherOpen
        if open.isEmpty { upgrade(app) } else { openToQuit = open }
    }

    /// Quits the open apps among `paths` right before their update. Nil when one stayed open, so
    /// that update is skipped; otherwise the paths it quit, to open again at the end.
    private func quitBeforeUpdate(_ paths: [String]) async -> [String]? {
        var quit: [String] = []
        for path in paths {
            guard let running = OpenApps.running(at: path) else { continue }
            guard await OpenApps.quit(running) else { return nil }
            quit.append(path)
        }
        return quit
    }

    /// Runs `brew upgrade --cask` for each selected cask in turn, so Stop can wait for the one in
    /// progress, then checks with `brew outdated` which of them are still behind. That check
    /// decides the result, because the upgrade's exit status does not say which cask failed.
    /// Selected apps from a download follow, one at a time (see `replace`).
    func upgrade(_ app: AppModel) {
        guard let path = Homebrew.executable() else { return }
        let tokens = selectedTokens
        let commands = tokens.compactMap { Homebrew.upgradeCommand(tokens: [$0], executable: path) }
        let others = selectedOutside
        guard commands.count == tokens.count, !(tokens.isEmpty && others.isEmpty) else { return }
        openToQuit = []
        runningUpdates = true
        stopRequested = false
        stage = .running
        let brewBundles = Dictionary(uniqueKeysWithValues: updates.map { ($0.token, bundles(of: $0)) })
        task = Task(.applications) {
            var skipped: [String] = []
            var stayedOpen: [String] = []
            var reopen: [String] = []
            for (token, command) in zip(tokens, commands) {
                if stopRequested { skipped.append(token); continue }
                guard let quit = await quitBeforeUpdate(brewBundles[token] ?? []) else { stayedOpen.append(token); continue }
                reopen += quit
                // A failed upgrade is in the console with its status; the check below reports it.
                try? await app.stream(command, environment: Homebrew.processEnvironment)
            }
            var done: [String] = []
            var lines: [String] = []
            var checked = true
            if !tokens.isEmpty {
                if let remaining = try? Set(Homebrew.parseOutdated(try await brew(app, path, Homebrew.outdatedArguments())).map(\.token)) {
                    done = tokens.filter { !remaining.contains($0) }
                    lines = done.map { "✓ \($0)" }
                        + stayedOpen.map { "✕ " + String(localized: "\($0): it stayed open, so it was not updated.") }
                        + tokens.filter { remaining.contains($0) && !skipped.contains($0) && !stayedOpen.contains($0) }.map { "✕ " + String(localized: "\($0) is still outdated") }
                        + skipped.filter { remaining.contains($0) }.map { "– " + String(localized: "\($0): not started, you pressed Stop") }
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
                guard let quit = await quitBeforeUpdate([item.path]) else {
                    lines.append("✕ " + String(localized: "\(item.name): it stayed open, so it was not updated."))
                    continue
                }
                reopen += quit
                if let problem = await replace(app, item, brew: path) {
                    lines.append("✕ \(item.name): \(problem)")
                } else {
                    done.append(item.path)
                    lines.append("✓ \(item.name) \(item.latest)")
                    outside.removeAll { $0.path == item.path }
                }
            }
            // Every app Nora quit comes back, updated or not.
            for bundle in reopen { OpenApps.reopen(bundle) }
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

    /// Hands an app from a download over to Homebrew: checks that Homebrew's own list has a newer
    /// version, moves the old copy to the Trash, runs `brew install --cask`, and puts the old copy
    /// back if the install fails. Nil on success, otherwise what went wrong.
    private func replace(_ app: AppModel, _ item: OutsideApps.Update, brew path: String) async -> String? {
        guard let token = item.token, let install = Homebrew.installCommand(token: token, executable: path) else {
            return String(localized: "Homebrew cannot install this app.")
        }
        // Quit just before this; an app reopened in between (by the user or a login item) stays.
        if OpenApps.running(at: item.path) != nil {
            return String(localized: "It is running. Quit it and try again.")
        }
        guard let data = try? await brew(app, path, Homebrew.infoArguments(token: token)),
              let version = try? Homebrew.parseVersion(data, token: token),
              OutsideApps.isNewer(version, than: item.installed) else {
            return String(localized: "Homebrew's app list has no newer version yet. Run brew update and try again.")
        }
        let original = URL(fileURLWithPath: item.path)
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: original, resultingItemURL: &trashed)
        } catch {
            return error.localizedDescription
        }
        // Journaled until brew is done, so a quit or crash mid-install still gets the copy back.
        let copy = trashed?.absoluteURL
        let entry = copy.map { OutsideApps.Journal.Entry(original: original.path, trashed: $0.path) }
        if let entry { app.handover.add(entry) }
        defer { if let entry { app.handover.remove(entry) } }
        do {
            try await app.stream(install, environment: Homebrew.processEnvironment)
            if FileManager.default.fileExists(atPath: original.path) { return nil }
        } catch {}
        // brew failed: the old copy goes back if its place is still free.
        guard let copy, !FileManager.default.fileExists(atPath: original.path),
              (try? FileManager.default.moveItem(at: copy, to: original)) != nil else {
            return String(localized: "Homebrew could not install it. The old version is in the Trash.")
        }
        return String(localized: "Homebrew could not install it. The old version is back in place.")
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

    func uninstall(_ app: AppModel) {
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
                    if result.succeeded {
                        removed.append(plan.app.name)
                        removedPaths.insert(plan.app.path)
                    } else {
                        problems.append(plan.app.name)
                    }
                } catch {
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
            let total = removed.count + problems.count + skipped.count
            resultHeadline = removed.isEmpty ? String(localized: "No app was removed")
                : failed ? String(localized: "Removed: \(removed.count) of \(total)")
                : permanent ? String(localized: "\(removed.count) apps removed") : String(localized: "\(removed.count) apps moved to the Trash")
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

    func cancelQuit() { openToQuit = [] }

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
                        title: model.stopRequested ? "Finishing the current app…" : model.runningUpdates ? "Updating apps…" : "Removing apps…",
                        detail: WorkingView.currentItem(app.console.output(of: module)),
                        onStop: model.stopRequested ? nil : { model.stopAfterCurrent() })
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
