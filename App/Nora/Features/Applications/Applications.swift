import MoleKit
import Observation
import SwiftUI

/// Applications. The scan (`mo uninstall --list`, bundle sizes, last-used dates and Homebrew cask
/// updates) leads to results and to three places: the full app list, the Homebrew updates, and
/// uninstalling. Uninstalling is unchanged: each app's plan comes from `mo uninstall --dry-run`,
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
    /// Why the updates are missing: Homebrew not found, or its check failed.
    var updatesNote: String?
    var selected: Set<String> = []
    var selectedUpdates: Set<String> = []
    var search = ""
    var plans: [Plan] = []
    var permanent = false
    var error: String?
    var scanTitle = "Looking at your apps…"
    var scanStep = ""
    var runningUpdates = false
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
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Scan

    func scan(_ app: AppModel) {
        error = nil
        scanTitle = "Looking at your apps…"
        scanStep = String(localized: "Listing apps")
        sizes = [:]
        lastUsed = [:]
        stage = .scanning
        task = Task {
            do {
                let listed = try await app.run(["uninstall", "--list"])
                guard listed.succeeded, let data = listed.stdout.data(using: .utf8) else {
                    throw NoraError.commandFailed(listed.stderr.isEmpty ? listed.stdout : listed.stderr)
                }
                apps = try InstalledApp.decodeList(data)
                scanStep = String(localized: "Measuring sizes and last use")
                await inspect()
                try Task.checkCancellation()
                scanStep = String(localized: "Checking Homebrew updates")
                await checkUpdates(app)
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
            updatesNote = String(localized: "Homebrew is not installed. Only Homebrew apps can be updated here.")
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

    /// One read-only brew call, logged to the console with its exit status.
    private func brew(_ app: AppModel, _ path: String, _ arguments: [String]) async throws -> Data {
        let id = app.console.begin(Homebrew.command(path, arguments))
        do {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: path), arguments, environment: Homebrew.processEnvironment)
            if !result.stderr.isEmpty { app.console.append(id, result.stderr.components(separatedBy: "\n")) }
            app.console.finish(id, status: result.status)
            guard result.succeeded else { throw NoraError.commandFailed(result.stderr.isEmpty ? "brew exited with status \(result.status)" : result.stderr) }
            return Data(result.stdout.utf8)
        } catch {
            app.console.fail(id, error: error)
            throw error
        }
    }

    // MARK: - Updates

    /// Runs `brew upgrade --cask` for the selected casks, then checks with `brew outdated` which of
    /// them are still behind. That check decides the result, because the upgrade's exit status
    /// does not say which cask failed.
    func upgrade(_ app: AppModel) {
        guard let path = Homebrew.executable() else { return }
        let tokens = selectedTokens
        guard let command = Homebrew.upgradeCommand(tokens: tokens, executable: path) else { return }
        runningUpdates = true
        stage = .running
        task = Task {
            // A failed upgrade is in the console with its status; the check below reports it.
            try? await app.stream(command, environment: Homebrew.processEnvironment)
            var remaining: Set<String>?
            do {
                remaining = Set(try Homebrew.parseOutdated(try await brew(app, path, Homebrew.outdatedArguments())).map(\.token))
            } catch {
                remaining = nil
            }
            if let remaining {
                let done = tokens.filter { !remaining.contains($0) }
                let left = tokens.filter { remaining.contains($0) }
                failed = done.isEmpty
                resultHeadline = done.isEmpty ? String(localized: "No app was updated") : String(localized: "\(done.count) apps updated")
                resultLines = done.map { "✓ \($0)" } + left.map { "✕ \($0) is still outdated" }
            } else {
                failed = true
                resultHeadline = String(localized: "Could not check the result")
                resultLines = ["Homebrew did not answer the check. See the console."]
            }
            selectedUpdates = []
            if let remaining { updates.removeAll { tokens.contains($0.token) && !remaining.contains($0.token) } }
            runningUpdates = false
            stage = .done
        }
    }

    // MARK: - Uninstall

    func review(_ app: AppModel) {
        plans = chosen.map { Plan(app: $0) }
        scanTitle = "Finding every file…"
        scanStep = String(localized: "Reading Mole's removal plan")
        stage = .scanning
        task = Task {
            for index in plans.indices {
                let target = plans[index].app
                do {
                    let (entries, _) = try await app.drive(["uninstall", "--dry-run", target.uninstallName]) { session in
                        try UninstallDriver().preview(app: target.name, in: session)
                    }
                    plans[index].entries = entries
                } catch {
                    plans[index].error = Self.describe(error)
                }
            }
            screen = .plans
            stage = .review
        }
    }

    func uninstall(_ app: AppModel) {
        let ready = plans.filter { $0.error == nil && !$0.entries.isEmpty }
        runningUpdates = false
        stage = .running
        task = Task {
            var removed: [String] = [], removedPaths: Set<String> = [], problems: [String] = []
            for plan in ready {
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
            apps.removeAll { removedPaths.contains($0.path) }
            unusedPaths.subtract(removedPaths)
            failed = removed.isEmpty
            resultHeadline = removed.isEmpty ? String(localized: "No app was removed")
                : permanent ? String(localized: "\(removed.count) apps removed") : String(localized: "\(removed.count) apps moved to the Trash")
            resultLines = removed.map { "✓ \($0)" } + problems.map { "✕ \($0)" }
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
        default:
            error.localizedDescription
        }
    }

    // MARK: - Navigation

    func openList(_ filter: ListFilter) {
        listFilter = filter
        screen = .list
    }

    func openUpdates(all: Bool) {
        selectedUpdates = all ? Set(updates.map(\.token)) : []
        screen = .updates
    }

    func stop() { task?.cancel() }

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
            WorkingView(module: module, title: model.runningUpdates ? "Updating apps…" : "Removing apps…",
                        detail: WorkingView.currentItem(app.console.entries.last?.output ?? []))
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) {
                model.reset()
            }
        }
    }

    private var start: some View {
        ModuleStart(module: module,
                    subtitle: "Remove an app with its helpers, caches and settings, update Homebrew apps, and find the ones you no longer open.",
                    features: [Feature(symbol: "trash", text: "Uninstaller"),
                               Feature(symbol: "arrow.triangle.2.circlepath", text: "Updates (Homebrew)"),
                               Feature(symbol: "clock.arrow.circlepath", text: "Unused apps"),
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
