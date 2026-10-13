import MoleKit
import Observation
import SwiftUI

/// Applications: `mo uninstall --list` (JSON) → pick apps → each app's removal plan from
/// `mo uninstall --dry-run <name>` → `mo uninstall <name>`, where the driver answers only when
/// Mole's plan matches the previewed one. Apps go to the Trash unless the user asks otherwise.
@MainActor @Observable
final class AppsModel {
    struct Plan: Identifiable {
        let app: InstalledApp
        var entries: [String] = []
        var error: String?
        var id: String { app.id }
    }

    var stage: FlowStage = .start
    var apps: [InstalledApp] = []
    var sizes: [String: Int64] = [:]
    var selected: Set<String> = []
    var search = ""
    var plans: [Plan] = []
    var permanent = false
    var error: String?
    var resultHeadline = ""
    var resultLines: [String] = []
    var failed = false
    var loaded = false
    @ObservationIgnored private var task: Task<Void, Never>?

    var visible: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(q) }
        return base.sorted { (sizes[$0.path] ?? -1) > (sizes[$1.path] ?? -1) }
    }

    var chosen: [InstalledApp] { apps.filter { selected.contains($0.path) } }
    var selectedSize: Int64 { chosen.reduce(0) { $0 + (sizes[$1.path] ?? 0) } }

    func load(_ app: AppModel) {
        guard !loaded else { return }
        error = nil
        task = Task {
            do {
                let result = try await app.run(["uninstall", "--list"])
                guard result.succeeded, let data = result.stdout.data(using: .utf8) else {
                    throw NoraError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
                }
                apps = try InstalledApp.decodeList(data)
                loaded = true
                await measure()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Mole lists sizes as "--"; Nora measures the bundles itself, off the main thread.
    private func measure() async {
        let paths = apps.map(\.path)
        for chunk in stride(from: 0, to: paths.count, by: 8).map({ Array(paths[$0..<min($0 + 8, paths.count)]) }) {
            let measured = await withTaskGroup(of: (String, Int64).self) { group in
                for path in chunk { group.addTask { (path, Self.allocatedSize(path)) } }
                var out: [(String, Int64)] = []
                for await item in group { out.append(item) }
                return out
            }
            for (path, size) in measured { sizes[path] = size }
        }
    }

    nonisolated static func allocatedSize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        while let file = walker.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func review(_ app: AppModel) {
        plans = chosen.map { Plan(app: $0) }
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
            stage = .review
        }
    }

    func uninstall(_ app: AppModel) {
        let ready = plans.filter { $0.error == nil && !$0.entries.isEmpty }
        stage = .running
        task = Task {
            var removed: [String] = [], problems: [String] = []
            for plan in ready {
                let args = ["uninstall", plan.app.uninstallName] + (permanent ? ["--permanent"] : [])
                let needsAdmin = !FileManager.default.isDeletableFile(atPath: plan.app.path)
                do {
                    let expected = Set(plan.entries)
                    let (_, result) = try await app.drive(args, sudo: needsAdmin) { session in
                        try UninstallDriver().uninstall(app: plan.app.name, expectedEntries: expected, in: session)
                    }
                    if result.succeeded { removed.append(plan.app.name) } else { problems.append(plan.app.name) }
                } catch {
                    problems.append("\(plan.app.name): \(Self.describe(error))")
                }
            }
            failed = removed.isEmpty
            resultHeadline = removed.isEmpty ? String(localized: "No app was removed")
                : permanent ? String(localized: "\(removed.count) apps removed") : String(localized: "\(removed.count) apps moved to the Trash")
            resultLines = removed.map { "✓ \($0)" } + problems.map { "✕ \($0)" }
            selected = []
            loaded = false
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

    func stop() { task?.cancel() }
    func back() { stage = .start; plans = [] }
}

struct ApplicationsView: View {
    @Environment(AppModel.self) private var app
    private var model: AppsModel { app.apps }
    private let module = Module.applications

    var body: some View {
        switch model.stage {
        case .start:
            AppsList(model: model).task { model.load(app) }
        case .scanning:
            WorkingView(module: module, title: "Finding every file…", detail: WorkingView.currentItem(app.console.entries.last?.output ?? []), onStop: { model.stop() })
        case .review:
            AppsReview(model: model)
        case .running:
            WorkingView(module: module, title: "Removing apps…", detail: WorkingView.currentItem(app.console.entries.last?.output ?? []))
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) {
                model.back(); model.load(app)
            }
        }
    }
}

private struct AppsList: View {
    @Bindable var model: AppsModel
    @Environment(AppModel.self) private var app
    private let module = Module.applications

    var body: some View {
        ModuleScene(module: module, orb: model.selected.isEmpty ? nil : OrbAction(title: "Uninstall", destructive: true, action: { model.review(app) })) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                GlassImage(name: module.glass, size: 72, glow: module.palette.glow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.system(size: 32, weight: .light)).shadow(color: module.palette.glow.opacity(0.5), radius: 12)
                    Text("Removes an app together with its helpers, caches and settings. Personal data stays.")
                        .font(.system(size: 13)).foregroundStyle(Palette.fg2)
                }
                Spacer()
                TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if let error = model.error { Notice(text: error, color: Palette.crit) }
            if !model.loaded && model.error == nil {
                ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { item in
                            row(item)
                            Divider().overlay(Palette.line)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel()
            }
            ReviewFooter(command: "mo uninstall " + model.chosen.map { ShellQuote.word($0.uninstallName) }.joined(separator: " "),
                         note: model.selected.isEmpty ? nil : String(localized: "\(model.selected.count) selected, \(Format.bytes(model.selectedSize))"))
        }
        .padding(.horizontal, 34).padding(.top, 8)
        }
    }

    private func row(_ item: InstalledApp) -> some View {
        Toggle(isOn: Binding(get: { model.selected.contains(item.path) },
                             set: { if $0 { model.selected.insert(item.path) } else { model.selected.remove(item.path) } })) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text((item.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let source = item.source, source != "App" {
                    Text(source).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(module.palette.glow.opacity(0.2)))
                }
                Text(model.sizes[item.path].map(Format.bytes) ?? "…").font(.system(size: 12, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.fg2).frame(width: 80, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 5)
    }
}

private struct AppsReview: View {
    @Bindable var model: AppsModel
    @Environment(AppModel.self) private var app
    @State private var confirmPermanent = false
    private let module = Module.applications

    var body: some View {
        ModuleScene(module: module, leading: .back { model.back() },
                    orb: OrbAction(title: model.permanent ? "Delete" : "Remove", destructive: true, action: {
                        if model.permanent { confirmPermanent = true } else { model.uninstall(app) }
                    })) {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(module: module, title: "Review removal", subtitle: String(localized: "\(model.plans.count) apps"))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.plans) { plan in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.path)).resizable().frame(width: 28, height: 28)
                                Text(plan.app.name).font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text("\(plan.entries.count) items").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            if let error = plan.error {
                                Notice(text: error, color: Palette.crit)
                            } else {
                                ForEach(plan.entries, id: \.self) { entry in
                                    Text(entry).font(.mono).foregroundStyle(Palette.fg2).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                }
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassPanel(radius: 14)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Delete permanently instead of moving to the Trash", isOn: $model.permanent).toggleStyle(.switch).controlSize(.small)
                Text("Nora answers Mole only if its list matches this preview.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, 34).padding(.top, 8)
        }
        .confirmationDialog("Delete these apps permanently?", isPresented: $confirmPermanent) {
            Button("Delete permanently", role: .destructive) { model.uninstall(app) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They skip the Trash and cannot be restored.")
        }
    }
}

enum ShellQuote {
    static func word(_ s: String) -> String { ShellCommand("", [s]).description.trimmingCharacters(in: .whitespaces) }
}
