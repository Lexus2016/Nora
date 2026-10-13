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
    @ObservationIgnored private var task: Task<Void, Never>?

    static let tiles: [Module] = [.cleanup, .performance, .projects, .installers]

    func scan(_ app: AppModel) {
        phase = .scanning
        app.cleanup.scan(app)
        app.performance.scan(app)
        app.projects.scan(app)
        app.installers.scan(app)
        task = Task {
            while Self.tiles.contains(where: { stage(of: $0, app) == .scanning }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            for module in Self.tiles where stage(of: module, app) != .review { enabled.remove(module) }
            phase = .results
        }
    }

    func run(_ app: AppModel) {
        phase = .running
        doneLines = []
        task = Task {
            for module in Self.tiles where enabled.contains(module) && stage(of: module, app) == .review {
                switch module {
                case .cleanup: app.cleanup.clean(app)
                case .performance: app.performance.run(app)
                case .projects: app.projects.purge(app)
                case .installers: app.installers.remove(app)
                default: continue
                }
                while stage(of: module, app) == .running { try? await Task.sleep(nanoseconds: 300_000_000) }
                doneLines.append("\(String(localized: String.LocalizationValue(module.titleText))): \(headline(of: module, app))")
            }
            phase = .done
        }
    }

    func stop(_ app: AppModel) {
        task?.cancel()
        app.cleanup.stop(); app.performance.stop(); app.projects.stop(); app.installers.stop()
        phase = .start
    }

    func reset(_ app: AppModel) {
        app.cleanup.reset(); app.performance.reset(); app.projects.reset(); app.installers.reset()
        enabled = Set(Self.tiles)
        phase = .start
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

    private func headline(of module: Module, _ app: AppModel) -> String {
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
                        features: [Feature(symbol: "trash", text: "Junk: caches, logs and leftovers"),
                                   Feature(symbol: "bolt", text: "Maintenance tasks"),
                                   Feature(symbol: "hammer", text: "Old build folders"),
                                   Feature(symbol: "shippingbox", text: "Installers you no longer need")],
                        command: "mo clean --dry-run · mo optimize --dry-run · mo purge --dry-run · mo installer --dry-run",
                        action: { model.scan(app) }) {
                if !app.hasFullDiskAccess {
                    HStack(spacing: 10) {
                        Notice(text: String(localized: "Give Nora Full Disk Access so Mole can also clean the Trash and app containers."), symbol: "lock.shield")
                        Button("Open settings") { Permissions.openFullDiskAccess() }.buttonStyle(GlassButtonStyle()).fixedSize()
                    }
                }
            }
                .task { if app.autoScan { model.scan(app) } }
        case .scanning, .results, .running:
            tiles
        case .done:
            DoneView(module: module, headline: String(localized: "Smart Care is done"), lines: model.doneLines) { model.reset(app) }
        }
    }

    private var tiles: some View {
        let orb: OrbAction? = switch model.phase {
        case .scanning: OrbAction(title: "Stop", busy: true, action: { model.stop(app) })
        case .results: model.enabled.isEmpty ? nil : OrbAction(title: "Run", action: { model.run(app) })
        case .running: OrbAction(title: "Running", busy: true, action: {})
        default: nil
        }
        return ModuleScene(module: module, leading: model.phase == .results ? .startOver { model.reset(app) } : nil, orb: orb) {
            VStack(spacing: 22) {
                Text(model.phase == .results ? String(localized: "Tasks are ready. Here is what we found:")
                     : model.phase == .running ? String(localized: "Working on it…") : String(localized: "Scanning your Mac…"))
                    .font(.system(size: 30, weight: .semibold))
                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow { tile(.cleanup); tile(.performance) }
                    GridRow { tile(.projects); tile(.installers) }
                }
            }
            .padding(.horizontal, 34).padding(.top, 14)
        }
    }

    private func tile(_ tileModule: Module) -> some View {
        SmartTile(module: tileModule, model: model)
    }
}

/// One Smart Care tile: the module's glass object off the corner, its finding, Review.
private struct SmartTile: View {
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
                        .toggleStyle(.checkbox).labelsHidden()
                }
                Text(module.title).font(.system(size: 16, weight: .semibold))
            }
            Spacer(minLength: 0)
            if working {
                Text(stage == .running ? "Running…" : "Checking…").font(.system(size: 26, weight: .semibold))
                Text(WorkingView.currentItem(app.console.entries.last(where: { $0.isRunning })?.output ?? []) ?? " ")
                    .font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(1).truncationMode(.middle)
            } else if let error = model.error(module, app) {
                Text("Could not check").font(.system(size: 22, weight: .semibold))
                Text(error).font(.system(size: 12)).foregroundStyle(Palette.warn).lineLimit(2)
            } else if let finding {
                Text(finding.value).font(.system(size: 36, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                HStack {
                    Text(finding.caption).font(.system(size: 14)).foregroundStyle(Palette.fg2)
                    Spacer()
                    if model.phase == .results {
                        Button("Review") { app.selection = module }.buttonStyle(GlassButtonStyle()).fixedSize()
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
        .animation(.easeInOut(duration: 0.3), value: working)
    }
}
