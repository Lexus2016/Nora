import AppKit
import MoleKit
import Observation
import SwiftUI

/// Tools: the smaller Mole commands, each as a card with its exact command.
@MainActor @Observable
final class ToolsModel {
    var touchIDEnabled: Bool?
    var touchIDBusy = false
    var touchIDError: String?
    @ObservationIgnored private var touchIDGeneration = UUID()
    @ObservationIgnored private var refreshGeneration = UUID()
    var latestMole: String?
    var updateBusy = false
    /// A preview belongs to one drive as it was mounted then: choosing another drive, or
    /// unplugging and remounting it, voids it, and Clean only runs for the drive that was previewed.
    var externalVolume: URL? {
        didSet {
            guard externalVolume != oldValue else { return }
            externalGeneration = UUID()
            externalPreview = []
            externalError = nil
            previewedVolume = nil
            externalBusy = false
        }
    }
    private(set) var previewedVolume: URL?
    @ObservationIgnored private var previewedIdentity: String?
    @ObservationIgnored private var externalGeneration = UUID()
    var externalPreview: [String] = []
    /// Why the last preview or clean of the drive failed, shown under its output.
    var externalError: String?
    var externalBusy = false
    /// While a drive is being cleaned the picker and Preview wait, so nothing overlaps the run.
    var externalCleaning = false
    @ObservationIgnored private var externalTask: Task<Void, Never>?
    @ObservationIgnored private var unmountObserver: NSObjectProtocol?

    init() {
        // Unplugging the chosen drive voids its preview at once, whatever its identifiers say.
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeUnmounted(url) }
        }
    }

    func volumeUnmounted(_ url: URL?) {
        guard let url, externalVolume?.standardizedFileURL == url.standardizedFileURL else { return }
        externalVolume = nil
    }
    var completionPreview: [String] = []
    var completionError: String?
    var completionBusy = false
    private(set) var completionPreviewValid = false
    var removeError: String?
    var removeBusy = false
    var removePreview: [String] = []
    var message: String?

    var volumes: [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") }
    }

    func refresh(_ app: AppModel) {
        let generation = UUID()
        refreshGeneration = generation
        Task(.tools) {
            if !touchIDBusy {
                let statusGeneration = UUID()
                touchIDGeneration = statusGeneration
                let outcome = await Self.attempt { try await app.run(["touchid", "status"]) }
                if touchIDGeneration == statusGeneration {
                    applyTouchIDStatus(outcome)
                }
            }
            let latest = try? await MoleSetup.latestVersion()
            guard refreshGeneration == generation else { return }
            latestMole = latest
        }
    }

    nonisolated static func touchIDState(_ result: CommandResult?) -> Bool? {
        guard let result, result.succeeded else { return nil }
        let text = ANSI.strip(result.stdout).lowercased()
        if text.contains("not configured") || text.contains("not enabled") || text.contains("disabled") { return false }
        if text.contains("enabled") || text.contains("configured") { return true }
        return nil
    }

    private func applyTouchIDStatus(_ outcome: Attempt) {
        touchIDEnabled = Self.touchIDState(outcome.result)
        touchIDError = Self.commandFailure(outcome)
        if touchIDEnabled == nil, touchIDError == nil {
            touchIDError = String(localized: "Mole returned an unknown Touch ID status. Check the console and retry.")
        }
    }

    func setTouchID(_ on: Bool, _ app: AppModel) {
        guard !touchIDBusy, touchIDEnabled != nil else { return }
        touchIDGeneration = UUID() // Invalidate an older status read before mutating.
        touchIDBusy = true
        touchIDError = nil
        Task(.tools) {
            defer { touchIDBusy = false }
            do {
                let result = try await app.runPTY(["touchid", on ? "enable" : "disable"], sudo: true)
                guard result.succeeded else {
                    touchIDEnabled = nil
                    touchIDError = Self.lastLine(result.text) ?? String(localized: "The Touch ID change did not finish. Check the console and retry.")
                    return
                }
                applyTouchIDStatus(await Self.attempt { try await app.run(["touchid", "status"]) })
                if let actual = touchIDEnabled, actual != on {
                    touchIDError = String(localized: "Touch ID does not match the requested setting. Check the console and retry.")
                }
            } catch {
                touchIDEnabled = nil
                touchIDError = error.localizedDescription
            }
        }
    }

    func updateMole(_ app: AppModel) {
        guard !updateBusy, let mole = app.mole else { return }
        updateBusy = true
        Task(.tools) {
            defer { updateBusy = false }
            do {
                try await app.stream(MoleSetup.updateCommand(for: mole), environment: mole.environment)
                message = String(localized: "The Mole update command finished. Check the installed version below.")
            } catch {
                message = String(localized: "The update did not finish. The console shows the output.")
            }
            await app.locate()
        }
    }

    func previewExternal(_ app: AppModel) {
        guard !externalCleaning, let volume = externalVolume else { return }
        let generation = UUID()
        externalGeneration = generation
        previewedVolume = nil
        externalBusy = true
        let identity = Self.identity(of: volume)
        Task(.tools) {
            defer { if externalGeneration == generation { externalBusy = false } }
            let outcome = await Self.attempt { try await app.run(["clean", "--external", volume.path, "--dry-run"]) }
            // A newer preview or another drive took over meanwhile: this result is stale.
            guard externalGeneration == generation, externalVolume == volume else { return }
            let result = outcome.result
            externalPreview = Self.meaningful(result?.stdout ?? "")
            externalError = Self.failure(outcome, preview: true)
            let valid = result?.succeeded == true && identity != nil && Self.identity(of: volume) == identity
            previewedVolume = valid ? volume : nil
            previewedIdentity = valid ? identity : nil
        }
    }

    func cleanExternal(_ app: AppModel) {
        guard !externalBusy, !externalCleaning, let volume = externalVolume, previewedVolume == volume else { return }
        guard let identity = previewedIdentity, Self.identity(of: volume) == identity else {
            previewedVolume = nil
            externalPreview = [String(localized: "The drive was unplugged or changed since the preview. Preview it again.")]
            return
        }
        let generation = UUID()
        externalGeneration = generation
        externalCleaning = true
        externalTask = Task(.tools) {
            defer { externalCleaning = false }
            let outcome = await Self.attempt { try await app.run(["clean", "--external", volume.path]) }
            // Only this run's own screen state is written; a newer preview stays as it is.
            guard externalGeneration == generation, externalVolume == volume else { return }
            externalPreview = Task.isCancelled ? [String(localized: "Stopped. Files removed before the stop stay removed.")]
                                               : MoleSummary.lines(outcome.result?.stdout ?? "")
            externalError = Task.isCancelled ? nil : Self.failure(outcome, preview: false)
            previewedVolume = nil
            previewedIdentity = nil
        }
    }

    func stopExternal() { externalTask?.cancel() }

    /// A command's result, or the error that kept it from running.
    struct Attempt { var result: CommandResult?; var error: Error? }

    static func attempt(_ body: () async throws -> CommandResult) async -> Attempt {
        do { return Attempt(result: try await body()) } catch { return Attempt(error: error) }
    }

    /// What went wrong, in words, or nil when the command succeeded. A failed clean may have
    /// removed some files already, so it never says that nothing changed.
    nonisolated static func failure(_ attempt: Attempt, preview: Bool) -> String? {
        let detail: String
        if let result = attempt.result {
            guard !result.succeeded else { return nil }
            detail = lastLine(result.stderr) ?? lastLine(result.stdout) ?? String(localized: "Mole exited with status \(result.status).")
        } else {
            detail = attempt.error?.localizedDescription ?? String(localized: "Mole could not start.")
        }
        return preview ? String(localized: "The preview failed: \(detail)")
                       : String(localized: "Cleaning did not finish: \(detail) Some files may already be removed; the console shows the output.")
    }

    nonisolated private static func lastLine(_ text: String) -> String? {
        ANSI.strip(text).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    /// The mounted drive as it is now: unmounting, remounting or swapping it gives a new value.
    static func identity(of volume: URL) -> String? {
        guard let values = try? volume.resourceValues(forKeys: [.volumeIdentifierKey, .volumeUUIDStringKey]),
              let id = values.volumeIdentifier else { return nil }
        return "\(values.volumeUUIDString ?? "")|\(id)"
    }

    /// Shared by the small tools: output alone never authorizes a follow-on action.
    nonisolated static func commandFailure(_ attempt: Attempt) -> String? {
        if let result = attempt.result {
            guard !result.succeeded else { return nil }
            return lastLine(result.stderr) ?? lastLine(result.stdout) ?? String(localized: "Mole exited with status \(result.status).")
        }
        return attempt.error?.localizedDescription ?? String(localized: "Mole could not start.")
    }

    func acceptCompletionPreview(_ outcome: Attempt) {
        completionPreview = Self.meaningful(outcome.result?.stdout ?? "")
        completionError = Self.commandFailure(outcome)
        completionPreviewValid = outcome.result?.succeeded == true && !completionPreview.isEmpty
    }

    func previewCompletion(_ app: AppModel) {
        guard !completionBusy else { return }
        completionBusy = true
        completionPreviewValid = false
        completionError = nil
        Task(.tools) {
            defer { completionBusy = false }
            acceptCompletionPreview(await Self.attempt { try await app.run(["completion", "--dry-run"]) })
        }
    }

    func installCompletion(_ app: AppModel) {
        guard !completionBusy, completionPreviewValid else { return }
        completionBusy = true
        completionPreviewValid = false
        completionError = nil
        Task(.tools) {
            defer { completionBusy = false }
            let outcome = await Self.attempt { try await app.run(["completion"]) }
            completionPreview = Self.meaningful(outcome.result?.stdout ?? "")
            completionError = Self.commandFailure(outcome)
        }
    }

    func previewRemove(_ app: AppModel) {
        guard !removeBusy else { return }
        removeBusy = true
        removeError = nil
        Task(.tools) {
            defer { removeBusy = false }
            let outcome = await Self.attempt { try await app.run(["remove", "--dry-run"]) }
            removePreview = Self.meaningful(outcome.result?.stdout ?? "")
            removeError = Self.commandFailure(outcome)
        }
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
        .task { if !app.isVisualSnapshot { model.refresh(app) } }
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
            if let error = model.touchIDError {
                Notice(text: error, color: Palette.crit)
                Button("Retry") { model.refresh(app) }.buttonStyle(GlassButtonStyle()).disabled(model.touchIDBusy)
            }
            HStack {
                Text(model.touchIDEnabled == nil ? (model.touchIDError == nil ? "Checking…" : "Unknown") : model.touchIDEnabled == true ? "On" : "Off").font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.touchIDBusy { Spinner() }
                Button(model.touchIDEnabled == true ? "Turn off" : "Turn on") { model.setTouchID(model.touchIDEnabled != true, app) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(model.touchIDEnabled == nil || model.touchIDBusy)
            }
        }
    }

    private var moleUpdate: some View {
        let installed = app.mole?.version ?? "?"
        let latest = model.latestMole
        return tool("Mole", "arrow.triangle.2.circlepath", command: app.mole.map { MoleSetup.updateCommand(for: $0).description } ?? "mo update") {
            InfoRow(label: "Installed", value: installed)
            InfoRow(label: "Latest release", value: latest ?? "…")
            HStack {
                Spacer()
                if model.updateBusy { Spinner() }
                Button("Update Mole") { model.updateMole(app) }.buttonStyle(PrimaryButtonStyle()).disabled(model.updateBusy)
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
            .disabled(model.externalCleaning)
            ForEach(Array(model.externalPreview.suffix(4).enumerated()), id: \.offset) { _, line in
                Text(MoleSummaryText.localize(line)).font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(1)
            }
            if let error = model.externalError { Notice(text: error, color: Palette.crit) }
            HStack {
                Spacer()
                if model.externalBusy || model.externalCleaning { Spinner() }
                if model.externalCleaning { Button("Stop") { model.stopExternal() }.buttonStyle(GlassButtonStyle()) }
                Button("Preview") { model.previewExternal(app) }.buttonStyle(GlassButtonStyle())
                    .disabled(model.externalVolume == nil || model.externalCleaning)
                Button("Clean") { model.cleanExternal(app) }.buttonStyle(PrimaryButtonStyle())
                    .disabled(model.externalVolume == nil || model.previewedVolume != model.externalVolume || model.externalBusy || model.externalCleaning)
            }
        }
    }

    private var completion: some View {
        tool("Shell completion", "terminal", command: "mo completion") {
            Text("Tab completion for mo in your shell. Nora shows the line it adds first.").font(.system(size: 13)).foregroundStyle(Palette.fg2)
            if let error = model.completionError { Notice(text: error, color: Palette.crit) }
            ForEach(Array(model.completionPreview.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line).font(.mono).foregroundStyle(Palette.fg2).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Preview") { model.previewCompletion(app) }.buttonStyle(GlassButtonStyle()).disabled(model.completionBusy)
                Button("Add") { model.installCompletion(app) }.buttonStyle(PrimaryButtonStyle()).disabled(!model.completionPreviewValid || model.completionBusy)
            }
        }
    }

    private var remove: some View {
        tool("Preview Mole removal", "xmark.app", command: "mo remove --dry-run") {
            Text("What removing Mole would delete. This card only previews; it does not remove Mole.").font(.system(size: 13)).foregroundStyle(Palette.fg2)
            if let error = model.removeError { Notice(text: error, color: Palette.crit) }
            ForEach(Array(model.removePreview.prefix(5).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Spacer()
                Button("Preview") { model.previewRemove(app) }.buttonStyle(GlassButtonStyle()).disabled(model.removeBusy)
            }
        }
    }
}
