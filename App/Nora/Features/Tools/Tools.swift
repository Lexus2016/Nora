import MoleKit
import Observation
import SwiftUI

/// Tools: the smaller Mole commands, each as a card with its exact command.
@MainActor @Observable
final class ToolsModel {
    var touchIDEnabled: Bool?
    var touchIDBusy = false
    var latestMole: String?
    var updateBusy = false
    var externalVolume: URL?
    var externalPreview: [String] = []
    var externalBusy = false
    var completionPreview: [String] = []
    var removePreview: [String] = []
    var message: String?

    var volumes: [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") }
    }

    func refresh(_ app: AppModel) {
        Task {
            if let result = try? await app.run(["touchid", "status"]) {
                let text = ANSI.strip(result.stdout).lowercased()
                touchIDEnabled = text.contains("not configured") || text.contains("disabled") ? false : text.contains("enabled") || text.contains("configured")
            }
            latestMole = try? await MoleSetup.latestVersion()
        }
    }

    func setTouchID(_ on: Bool, _ app: AppModel) {
        touchIDBusy = true
        Task {
            defer { touchIDBusy = false }
            _ = try? await app.runPTY(["touchid", on ? "enable" : "disable"], sudo: true)
            refresh(app)
        }
    }

    func updateMole(_ app: AppModel) {
        guard let mole = app.mole else { return }
        updateBusy = true
        Task {
            defer { updateBusy = false }
            do {
                try await app.stream(MoleSetup.updateCommand(for: mole), environment: mole.environment)
                message = String(localized: "Mole is up to date.")
            } catch {
                message = String(localized: "The update did not finish. The console shows the output.")
            }
            await app.locate()
        }
    }

    func previewExternal(_ app: AppModel) {
        guard let volume = externalVolume else { return }
        externalBusy = true
        Task {
            defer { externalBusy = false }
            let result = try? await app.run(["clean", "--external", volume.path, "--dry-run"])
            externalPreview = Self.meaningful(result?.stdout ?? "")
        }
    }

    func cleanExternal(_ app: AppModel) {
        guard let volume = externalVolume else { return }
        externalBusy = true
        Task {
            defer { externalBusy = false }
            let result = try? await app.run(["clean", "--external", volume.path])
            externalPreview = MoleSummary.lines(result?.stdout ?? "")
        }
    }

    func previewCompletion(_ app: AppModel) {
        Task { completionPreview = Self.meaningful((try? await app.run(["completion", "--dry-run"]))?.stdout ?? "") }
    }

    func installCompletion(_ app: AppModel) {
        Task {
            let result = try? await app.run(["completion"])
            completionPreview = Self.meaningful(result?.stdout ?? "")
        }
    }

    func previewRemove(_ app: AppModel) {
        Task { removePreview = Self.meaningful((try? await app.run(["remove", "--dry-run"]))?.stdout ?? "") }
    }

    static func meaningful(_ text: String) -> [String] {
        text.split(separator: "\n").map { ANSI.strip(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("→ DRY RUN") && !$0.hasPrefix("=") }
    }
}

struct ToolsView: View {
    @Environment(AppModel.self) private var app
    private var model: ToolsModel { app.tools }
    private let module = Module.tools

    var body: some View {
        ModuleScene(module: module) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 18) {
                        Glass3D(name: module.glass, size: 110, glow: module.palette.glow, amplitude: 0)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(module.title).font(.system(size: 44, weight: .light))
                            Text("Smaller Mole commands, each with the exact command it runs.").font(.system(size: 15)).foregroundStyle(Palette.fg2)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                        touchID
                        moleUpdate
                        external
                        completion
                        remove
                    }
                    if let message = model.message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                }
                .padding(.horizontal, 34).padding(.top, 6).padding(.bottom, 20)
            }
            .scrollIndicators(.never)
        }
        .task { model.refresh(app) }
    }

    private func tool<Content: View>(_ title: LocalizedStringKey, _ symbol: String, command: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 19, weight: .semibold))
                Spacer()
                FeatureDisc(symbol: symbol, tint: module.palette.glow, size: 40)
            }
            content()
            Spacer(minLength: 0)
            CommandPreview(command: command)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(VolumeFill(radius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .volumeCard(radius: 20, tint: module.palette.glow)
    }

    private var touchID: some View {
        tool("Touch ID for sudo", "touchid", command: model.touchIDEnabled == true ? "mo touchid disable" : "mo touchid enable") {
            Text("Approve administrator tasks with your fingerprint instead of typing the password.").font(.system(size: 13)).foregroundStyle(Palette.fg2)
            HStack {
                Text(model.touchIDEnabled == nil ? "Checking…" : model.touchIDEnabled == true ? "On" : "Off").font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.touchIDBusy { ProgressView().controlSize(.small) }
                Button(model.touchIDEnabled == true ? "Turn off" : "Turn on") { model.setTouchID(model.touchIDEnabled != true, app) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(model.touchIDEnabled == nil || model.touchIDBusy)
            }
        }
    }

    private var moleUpdate: some View {
        let installed = app.mole?.version ?? "?"
        let latest = model.latestMole
        let behind = latest.map { Mole.compare(installed, $0) == .orderedAscending } ?? false
        return tool("Mole", "arrow.triangle.2.circlepath", command: app.mole.map { MoleSetup.updateCommand(for: $0).description } ?? "mo update") {
            InfoRow(label: "Installed", value: installed)
            InfoRow(label: "Latest release", value: latest ?? "…")
            HStack {
                Spacer()
                if model.updateBusy { ProgressView().controlSize(.small) }
                Button(behind ? "Update Mole" : "Reinstall") { model.updateMole(app) }.buttonStyle(PrimaryButtonStyle()).disabled(model.updateBusy)
            }
        }
    }

    private var external: some View {
        @Bindable var model = model
        return tool("External drive", "externaldrive", command: "mo clean --external \(model.externalVolume.map { ShellQuote.word($0.path) } ?? "/Volumes/…")") {
            Text("Removes macOS metadata such as .DS_Store and ._ files from a drive you plug in.").font(.system(size: 13)).foregroundStyle(Palette.fg2)
            Picker("", selection: $model.externalVolume) {
                Text("Choose a drive").tag(URL?.none)
                ForEach(model.volumes, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
            }
            .labelsHidden()
            ForEach(Array(model.externalPreview.suffix(4).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(1)
            }
            HStack {
                Spacer()
                if model.externalBusy { ProgressView().controlSize(.small) }
                Button("Preview") { model.previewExternal(app) }.buttonStyle(GlassButtonStyle()).disabled(model.externalVolume == nil)
                Button("Clean") { model.cleanExternal(app) }.buttonStyle(PrimaryButtonStyle()).disabled(model.externalVolume == nil || model.externalPreview.isEmpty)
            }
        }
    }

    private var completion: some View {
        tool("Shell completion", "terminal", command: "mo completion") {
            Text("Tab completion for mo in your shell. Nora shows the line it adds first.").font(.system(size: 13)).foregroundStyle(Palette.fg2)
            ForEach(Array(model.completionPreview.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line).font(.mono).foregroundStyle(Palette.fg2).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Preview") { model.previewCompletion(app) }.buttonStyle(GlassButtonStyle())
                Button("Add") { model.installCompletion(app) }.buttonStyle(PrimaryButtonStyle()).disabled(model.completionPreview.isEmpty)
            }
        }
    }

    private var remove: some View {
        tool("Remove Mole", "trash", command: "mo remove") {
            Text("What removing Mole would delete. Nora needs Mole, so the removal itself runs in Terminal.").font(.system(size: 13)).foregroundStyle(Palette.fg2)
            ForEach(Array(model.removePreview.prefix(5).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Preview") { model.previewRemove(app) }.buttonStyle(GlassButtonStyle())
            }
        }
    }
}
