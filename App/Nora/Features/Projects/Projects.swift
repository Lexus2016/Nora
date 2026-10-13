import MoleKit
import Observation
import SwiftUI

/// Projects: `mo purge --dry-run` → pick artifacts → `mo purge --yes`. Unchecked artifacts are
/// protected for the run by the whitelist overlay, which `mo purge` honours per artifact.
@MainActor @Observable
final class ProjectsModel {
    var stage: FlowStage = .start
    var preview: PurgePreview?
    var selected: Set<String> = []
    var error: String?
    var resultHeadline = ""
    var resultLines: [String] = []
    var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var selectedSize: Int64 { preview?.items.reduce(0) { selected.contains($1.path) ? $0 + $1.size : $0 } ?? 0 }

    /// Artifacts grouped by project folder, largest project first.
    var groups: [(project: String, items: [PurgePreview.Item])] {
        let grouped = Dictionary(grouping: preview?.items ?? [], by: \.project)
        return grouped.map { ($0.key, $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.items.reduce(0) { $0 + $1.size } > $1.items.reduce(0) { $0 + $1.size } }
    }

    func scan(_ app: AppModel) {
        error = nil
        stage = .scanning
        task = Task {
            do {
                let result = try await app.run(["purge", "--dry-run"])
                let parsed = PurgePreview.parse(result.stdout, home: app.home)
                // Exit 1 means "incomplete" (a slow root was skipped); the listed items are still valid.
                if parsed.items.isEmpty && !result.succeeded && parsed.warnings.isEmpty {
                    throw NoraError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
                }
                preview = parsed
                selected = Set(parsed.items.map(\.path))
                stage = .review
            } catch is CancellationError {
                stage = .start
            } catch {
                self.error = error.localizedDescription
                stage = .start
            }
        }
    }

    /// `mo purge --yes` takes every eligible folder it finds, not a list. So right before the run
    /// Nora takes a fresh read-only preview and protects everything in it that the user did not
    /// tick, including folders that appeared after the review. An incomplete preview means Mole
    /// may reach folders nobody saw, so nothing runs.
    func purge(_ app: AppModel) {
        guard preview != nil, let mole = app.mole else { return }
        let chosen = selected
        let runID = "purge-\(UUID().uuidString)"
        // Taken before the fresh preview: under another run's overlay that preview would miss
        // the folders that run protects, and they would lose protection when it ends.
        guard app.beginExclusiveRun(runID) else {
            failed = true
            resultHeadline = CleanupModel.describe(WhitelistOverlayError.pendingRecovery)
            resultLines = []
            stage = .done
            return
        }
        stage = .running
        task = Task {
            defer {
                try? app.overlay.recover(runID: runID)
                app.endExclusiveRun(runID)
            }
            do {
                let check = try await app.run(["purge", "--dry-run"])
                let fresh = PurgePreview.parse(check.stdout, home: app.home)
                guard check.succeeded, fresh.isComplete else {
                    throw NoraError.commandFailed(String(localized: "Some project folders could not be scanned completely, so nothing was removed. Scan again, or limit the folders in Protection."))
                }
                // Nothing the user ticked is left, so there is nothing to purge. Running anyway would
                // let Mole take whatever appears between this check and its own scan.
                guard fresh.items.contains(where: { chosen.contains($0.path) }) else {
                    throw NoraError.commandFailed(String(localized: "The folders you chose are already gone, so nothing was removed."))
                }
                let protected = fresh.items.map(\.path).filter { !chosen.contains($0) }
                if !protected.isEmpty {
                    try app.overlay.apply(protecting: protected, defaults: try mole.installation.cleanWhitelistDefaults(home: app.home), runID: runID)
                }
                let result = try await app.run(["purge", "--yes"])
                let summary = MoleSummary.lines(result.stdout)
                let freed = summary.first(where: { $0.contains("space freed") })?
                    .components(separatedBy: ":").last?.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces)
                failed = !result.succeeded
                resultHeadline = failed ? (freed.map { String(localized: "Partly done: \($0) freed") } ?? String(localized: "Removal did not finish"))
                                        : (freed ?? Format.bytes(selectedSize))
                resultLines = summary
            } catch {
                failed = true
                resultHeadline = CleanupModel.describe(error)
            }
            stage = .done
        }
    }

    func stop() { task?.cancel() }
    func reset() { stage = .start; preview = nil; selected = [] }
}

struct ProjectsView: View {
    @Environment(AppModel.self) private var app
    private var model: ProjectsModel { app.projects }
    private let module = Module.projects

    var body: some View {
        switch model.stage {
        case .start:
            ModuleStart(module: module,
                        subtitle: "Build folders of your code projects take gigabytes and come back with the next build.",
                        features: [Feature(symbol: "shippingbox", text: "node_modules, target, build, dist"),
                                   Feature(symbol: "chevron.left.forwardslash.chevron.right", text: ".venv, __pycache__, .gradle"),
                                   Feature(symbol: "clock", text: "Recently active projects stay untouched")],
                        command: "mo purge --dry-run",
                        action: { model.scan(app) }) {
                if let error = model.error { Notice(text: error, color: Palette.crit) }
            }
            .task { if app.autoScan { model.scan(app) } }
        case .scanning:
            WorkingView(module: module, title: "Looking for build folders…", detail: WorkingView.currentItem(app.console.entries.last?.output ?? []), onStop: { model.stop() })
        case .review:
            ProjectsReview(model: model)
        case .running:
            WorkingView(module: module, title: "Removing build folders…", detail: WorkingView.currentItem(app.console.entries.last?.output ?? []))
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) { model.reset() }
        }
    }
}

private struct ProjectsReview: View {
    @Bindable var model: ProjectsModel
    @Environment(AppModel.self) private var app
    @State private var expanded: Set<String> = []
    private let module = Module.projects

    var body: some View {
        ModuleScene(module: module, leading: .startOver { model.reset() },
                    orb: model.selected.isEmpty || model.preview?.isComplete == false ? nil : OrbAction(title: "Remove", destructive: true, action: { model.purge(app) })) {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(module: module, title: "Review build folders",
                       subtitle: String(localized: "\(Format.bytes(model.selectedSize)) selected")) {
                SelectAllButton(ids: model.preview?.items.map(\.path) ?? [], selection: $model.selected)
            }
            if let preview = model.preview {
                if !preview.isComplete {
                    Notice(text: String(localized: "Some project folders could not be scanned completely, so nothing was removed. Scan again, or limit the folders in Protection."))
                }
                ForEach(Array(preview.warnings.prefix(2).enumerated()), id: \.offset) { _, w in Notice(text: w, symbol: "info.circle", color: Palette.fg2) }
                if preview.items.isEmpty {
                    Text("No old build folders found.").font(.system(size: 15)).foregroundStyle(Palette.fg2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.groups, id: \.project) { group in
                                projectRows(group.project, group.items)
                                Divider().overlay(Palette.line)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassPanel()
                }
            }
            ReviewFooter(command: "mo purge --yes", note: String(localized: "Build folders are deleted permanently; the next install or build recreates them."))
        }
        .padding(.horizontal, 34).padding(.top, 8)
        }
    }

    @ViewBuilder private func projectRows(_ project: String, _ items: [PurgePreview.Item]) -> some View {
        let isExpanded = expanded.contains(project)
        let selectedCount = items.filter { model.selected.contains($0.path) }.count
        HStack(spacing: 10) {
            Button { if isExpanded { expanded.remove(project) } else { expanded.insert(project) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 16, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Palette.fg2)
            Toggle(isOn: Binding(get: { selectedCount == items.count }, set: { on in
                for item in items { if on { model.selected.insert(item.path) } else { model.selected.remove(item.path) } }
            })) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((project as NSString).lastPathComponent).font(.system(size: 14, weight: .medium))
                        Text((project as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(Format.bytes(items.reduce(0) { $0 + $1.size })).font(.system(size: 13, design: .rounded)).monospacedDigit()
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(.vertical, 5)
        if isExpanded {
            ForEach(items) { item in
                CheckRow(isOn: Binding(get: { model.selected.contains(item.path) },
                                       set: { if $0 { model.selected.insert(item.path) } else { model.selected.remove(item.path) } }),
                         title: (item.path as NSString).lastPathComponent, size: item.size, tint: module.palette.glow)
                    .padding(.leading, 26)
            }
        }
    }
}
