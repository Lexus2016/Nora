import MoleKit
import Observation
import SwiftUI

/// Smart Care: one Scan runs the previews of Cleanup, Performance, Projects and Installers side
/// by side (they are all read-only), then Run applies the checked ones one after another.
/// Each tile's Review opens that module's own review, already filled in.
@MainActor @Observable
final class SmartCareModel {
    enum Phase { case start, scanning, results, running, done }
    var phase: Phase = .start
    var enabled: Set<Module> = [.cleanup, .performance, .projects, .installers]
    var doneLines: [String] = []
    /// Modules whose run failed or only partly finished; Done reports them instead of a plain success.
    var failedModules: [Module] = []
    /// Stop was pressed during Run: the module in progress stops, the ones after it are not started.
    var stopRequested = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private var scanGeneration = UUID()
    /// The scans Smart Care itself started; Stop during Scan stops only these.
    @ObservationIgnored private var startedScans: Set<Module> = []
    /// The module whose run Smart Care started and is waiting for; Stop during Run stops only it.
    @ObservationIgnored private var runningModule: Module?

    static let tiles: [Module] = [.cleanup, .performance, .projects, .installers]

    func scan(_ app: AppModel) {
        guard phase != .scanning, phase != .running else { return }
        task?.cancel()
        let generation = UUID()
        scanGeneration = generation
        phase = .scanning
        // A module that is running keeps its run, and one already scanning keeps its scan, which
        // Smart Care then waits for: starting it again would leave the first scan writing over
        // the module's state later, even under a run.
        let idle = { (module: Module) in ![.running, .scanning].contains(self.stage(of: module, app)) }
        startedScans = Set(Self.tiles.filter(idle))
        if startedScans.contains(.cleanup) { app.cleanup.scan(app) }
        if startedScans.contains(.performance) { app.performance.scan(app) }
        if startedScans.contains(.projects) { app.projects.scan(app) }
        if startedScans.contains(.installers) { app.installers.scan(app) }
        task = Task {
            guard !Task.isCancelled, generation == scanGeneration else { return }
            while Self.tiles.contains(where: { stage(of: $0, app) == .scanning }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, generation == scanGeneration else { return }
            for module in Self.tiles where stage(of: module, app) != .review { enabled.remove(module) }
            phase = .results
        }
    }

    func run(_ app: AppModel) {
        let runnable = runnableModules(app)
        guard phase == .results, !runnable.isEmpty else { return }
        phase = .running
        doneLines = []
        failedModules = []
        stopRequested = false
        task = Task {
            for module in runnable {
                if stopRequested {
                    doneLines.append("– \(String(localized: String.LocalizationValue(module.titleText))): " + String(localized: "not started, you pressed Stop"))
                    continue
                }
                // Nothing found, or everything unticked in its review: nothing runs, nothing fails.
                guard stage(of: module, app) == .review, canRun(module, app) else {
                    doneLines.append("– \(String(localized: String.LocalizationValue(module.titleText))): " + String(localized: "nothing to do"))
                    continue
                }
                runningModule = module
                switch module {
                case .cleanup: app.cleanup.clean(app)
                case .performance: app.performance.run(app)
                case .projects: app.projects.purge(app)
                case .installers: app.installers.remove(app)
                default: continue
                }
                guard stage(of: module, app) == .running || stage(of: module, app) == .done else {
                    runningModule = nil
                    failedModules.append(module)
                    doneLines.append("✕ \(String(localized: String.LocalizationValue(module.titleText))): " + String(localized: "The task could not start"))
                    continue
                }
                while stage(of: module, app) == .running { try? await Task.sleep(nanoseconds: 300_000_000) }
                runningModule = nil
                let failed = self.failed(module, app)
                if failed { failedModules.append(module) }
                doneLines.append("\(failed ? "✕" : "✓") \(String(localized: String.LocalizationValue(module.titleText))): \(headline(of: module, app))")
            }
            phase = .done
        }
    }

    /// One eligibility rule shared by Run, its command preview and enabled state.
    func runnableModules(_ app: AppModel) -> [Module] {
        Self.tiles.filter { enabled.contains($0) && stage(of: $0, app) == .review && canRun($0, app) }
    }

    func canRun(_ module: Module, _ app: AppModel) -> Bool {
        guard hasWork(module, app) else { return false }
        switch module {
        case .cleanup: return app.cleanup.canClean
        case .projects: return app.projects.preview?.isComplete == true
        case .performance: return app.performance.canRun
        default: return true
        }
    }

    func retry(_ module: Module, _ app: AppModel) {
        guard phase == .results, !app.isBusy(module) else { return }
        enabled.insert(module)
        switch module {
        case .cleanup: app.cleanup.scan(app)
        case .performance: app.performance.scan(app)
        case .projects: app.projects.scan(app)
        case .installers: app.installers.scan(app)
        default: break
        }
    }

    /// False when a module's review has nothing ticked, so its command would have nothing to remove.
    func hasWork(_ module: Module, _ app: AppModel) -> Bool {
        switch module {
        case .cleanup: !app.cleanup.selected.isEmpty
        case .projects: !app.projects.selected.isEmpty
        case .installers: !app.installers.selected.isEmpty
        default: true
        }
    }

    /// Stop during Run. The loop is not cancelled: it waits for the stopped module and reports it.
    func stopRun(_ app: AppModel) {
        stopRequested = true
        // Only the step Smart Care started: a module the user runs on its own screen goes on.
        if let module = runningModule, stage(of: module, app) == .running {
            switch module {
            case .cleanup: app.cleanup.stop()
            case .performance: app.performance.stop()
            case .projects: app.projects.stop()
            case .installers: app.installers.stop()
            default: break
            }
        }
    }

    func stop(_ app: AppModel) {
        scanGeneration = UUID()
        task?.cancel()
        for module in startedScans where stage(of: module, app) == .scanning {
            switch module {
            case .cleanup: app.cleanup.stop()
            case .performance: app.performance.stop()
            case .projects: app.projects.stop()
            case .installers: app.installers.stop()
            default: break
            }
        }
        startedScans = []
        phase = .start
    }

    /// Start over never resets a module whose command is still running: its state and overlay
    /// belong to that run until it ends.
    func reset(_ app: AppModel) {
        guard phase != .running, !Self.tiles.contains(where: { app.isBusy($0) }) else { return }
        scanGeneration = UUID()
        task?.cancel()
        if app.cleanup.stage != .running { app.cleanup.reset() }
        if app.performance.stage != .running { app.performance.reset() }
        if app.projects.stage != .running { app.projects.reset() }
        if app.installers.stage != .running { app.installers.reset() }
        enabled = Set(Self.tiles)
        phase = .start
    }

    func failed(_ module: Module, _ app: AppModel) -> Bool {
        switch module {
        case .cleanup: app.cleanup.failed
        case .performance: app.performance.failed
        case .projects: app.projects.failed
        case .installers: app.installers.failed
        default: false
        }
    }

    func stage(of module: Module, _ app: AppModel) -> FlowStage {
        switch module {
        case .cleanup: app.cleanup.stage
        case .performance: app.performance.stage
        case .projects: app.projects.stage
        case .installers: app.installers.stage
        default: .start
        }
    }

    func headline(of module: Module, _ app: AppModel) -> String {
        switch module {
        case .cleanup: app.cleanup.resultHeadline
        case .performance: app.performance.resultHeadline
        case .projects: app.projects.resultHeadline
        case .installers: app.installers.resultHeadline
        default: ""
        }
    }

    /// What the tile shows after the scan: the number and the line under it.
    func finding(_ module: Module, _ app: AppModel) -> (value: String, caption: String)? {
        guard stage(of: module, app) == .review else { return nil }
        switch module {
        case .cleanup:
            guard app.cleanup.preview != nil else { return nil }
            return (Format.bytes(app.cleanup.selectedSize), String(localized: "of junk to clean"))
        case .performance:
            guard app.performance.report != nil else { return nil }
            let n = app.performance.pendingCount ?? 0
            return (String(localized: "\(n) tasks"), String(localized: "to run"))
        case .projects:
            guard app.projects.preview != nil else { return nil }
            return (Format.bytes(app.projects.selectedSize), String(localized: "in old build folders"))
        case .installers:
            guard app.installers.stage == .review else { return nil }
            return (String(localized: "\(app.installers.files.count) files"), String(localized: "\(Format.bytes(app.installers.selectedSize)) of installers"))
        default:
            return nil
        }
    }

    func error(_ module: Module, _ app: AppModel) -> String? {
        switch module {
        case .cleanup: app.cleanup.error
        case .performance: app.performance.error
        case .projects: app.projects.error
        case .installers: app.installers.error
        default: nil
        }
    }
}

struct SmartCareView: View {
    @Environment(AppModel.self) private var app
    private var model: SmartCareModel { app.smartCare }
    private let module = Module.smartCare

    var body: some View {
        switch model.phase {
        case .start:
            ModuleStart(module: module,
                        subtitle: "One scan for everything that takes space or slows your Mac. Nothing is deleted until you run it.",
                        features: [Feature(symbol: Module.cleanup.symbol, text: "Junk: caches, logs and leftovers"),
                                   Feature(symbol: Module.performance.symbol, text: "Maintenance tasks"),
                                   Feature(symbol: Module.projects.symbol, text: "Old build folders"),
                                   Feature(symbol: Module.installers.symbol, text: "Installers you no longer need")],
                        command: "mo clean --dry-run; mo optimize --dry-run; mo purge --dry-run; mo installer --dry-run",
                        action: { model.scan(app) }) {
                if !app.hasFullDiskAccess {
                    HStack(spacing: 10) {
                        Notice(text: String(localized: "Give Nora Full Disk Access so Mole can also clean the Trash and app containers."), symbol: "hand.raised")
                        Button("Open settings") { Permissions.openFullDiskAccess() }.buttonStyle(GlassButtonStyle()).fixedSize()
                    }
                }
            }
                .task { if app.autoScan { model.scan(app) } }
        case .scanning, .results, .running:
            tiles
        case .done:
            DoneView(module: module,
                     headline: model.stopRequested ? String(localized: "Smart Care stopped") : model.failedModules.isEmpty ? String(localized: "Smart Care is done")
                                                           : String(localized: "Smart Care finished with problems"),
                     lines: model.doneLines, failed: !model.failedModules.isEmpty) { model.reset(app) }
        }
    }

    private var tiles: some View {
        let orb: OrbAction? = switch model.phase {
        case .scanning: OrbAction(title: "Stop", busy: true, action: { model.stop(app) })
        case .results: OrbAction(title: "Run", enabled: !model.runnableModules(app).isEmpty, disabledReason: String(localized: "Select a ready task, or review and rescan a module"), action: { model.run(app) })
        case .running: model.stopRequested ? OrbAction(title: "Stopping", busy: true, action: {})
                                            : OrbAction(title: "Stop", busy: true, action: { model.stopRun(app) })
        default: nil
        }
        return ModuleScene(module: module, leading: model.phase == .results && !SmartCareModel.tiles.contains(where: { app.isBusy($0) }) ? .startOver { model.reset(app) } : nil, orb: orb) {
            VStack(spacing: 22) {
                Text(model.phase == .results ? String(localized: "Tasks are ready. Here is what we found:")
                     : model.phase == .running ? String(localized: "Working on it…") : String(localized: "Scanning your Mac…"))
                    .font(.system(size: 30, weight: .semibold))
                if model.phase == .results, !model.enabled.isEmpty {
                    Text("Run does every ticked task, one after another.").font(.system(size: 15)).foregroundStyle(Palette.fg2)
                }
                if model.phase == .results {
                    SelectAllButton(ids: [Module.cleanup, .performance, .projects, .installers].filter { model.finding($0, app) != nil },
                                    selection: Bindable(model).enabled)
                }
                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow { tile(.cleanup); tile(.performance) }
                    GridRow { tile(.projects); tile(.installers) }
                }
                if model.phase == .results, !runCommand.isEmpty {
                    CommandPreview(command: runCommand).frame(maxWidth: 640)
                }
            }
            .padding(.horizontal, 34).padding(.top, 14)
        }
    }

    /// Every command Run starts, in order, for the ticked tiles that have something to do.
    private var runCommand: String {
        model.runnableModules(app)
            .map { module -> String in
                switch module {
                case .cleanup: app.cleanup.command
                case .performance: "sudo -A -v && mo optimize"
                case .projects: "mo purge --yes"
                default: "MOLE_DELETE_MODE=trash mo installer"
                }
            }
            .joined(separator: "; ")
    }

    private func tile(_ tileModule: Module) -> some View {
        SmartTile(module: tileModule, model: model)
    }
}

/// One Smart Care tile: the module's glass object off the corner, its finding, Review.
private struct SmartTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    let module: Module
    @Bindable var model: SmartCareModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let stage = model.stage(of: module, app)
        let working = stage == .scanning || stage == .running
        let finding = model.finding(module, app)
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.phase == .results, finding != nil {
                    Toggle("", isOn: Binding(get: { model.enabled.contains(module) },
                                             set: { if $0 { model.enabled.insert(module) } else { model.enabled.remove(module) } }))
                        .toggleStyle(.checkbox).labelsHidden().disabled(!model.canRun(module, app))
                }
                Text(module.title).font(.system(size: 16, weight: .semibold))
            }
            Spacer(minLength: 0)
            if working {
                Text(stage == .running ? "Running…" : "Checking…").font(.system(size: 26, weight: .semibold))
                Text(WorkingView.currentItem(app.console.output(of: module)) ?? " ")
                    .font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(1).truncationMode(.middle)
            } else if let error = model.error(module, app) {
                Text("Could not check").font(.system(size: 22, weight: .semibold))
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.warn).lineLimit(2).help(error)
                if model.phase == .results {
                    Button("Retry") { model.retry(module, app) }.buttonStyle(GlassButtonStyle())
                }
            } else if stage == .done {
                Text(model.headline(of: module, app)).font(.system(size: 18, weight: .semibold)).lineLimit(3)
                Button("Review result") { app.reviewFromSmartCare(module) }.buttonStyle(GlassButtonStyle())
            } else if let finding {
                Text(finding.value).font(.system(size: 36, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                HStack {
                    Text(finding.caption).font(.system(size: 14)).foregroundStyle(Palette.fg2)
                    Spacer()
                    if model.phase == .results {
                        Button("Review") { app.reviewFromSmartCare(module) }.buttonStyle(GlassButtonStyle()).fixedSize()
                            // The glass object can reach under the button; its own 24% black is too thin for 4.5:1.
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.5)))
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topTrailing) {
            Glass3D(name: module.glass, size: 230, glow: module.palette.glow, amplitude: working ? 26 : 0)
                .offset(x: 50, y: -40)
        }
        .background(VolumeFill(radius: 24))
        .background(shape.fill(LinearGradient(colors: [module.palette.body.opacity(working ? 0.75 : 0.45), module.palette.depth.opacity(0.55)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
        .clipShape(shape)
        .volumeCard(radius: 24, tint: module.palette.glow)
        .overlay(shape.strokeBorder(.white.opacity(working ? 0.4 : 0), lineWidth: 1.2))
        .shadow(color: module.palette.glow.opacity(working ? 0.45 : 0), radius: 24)
        .animation(DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState) ? .easeInOut(duration: 0.3) : nil, value: working)
    }
}
