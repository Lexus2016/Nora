import MoleKit
import Observation
import SwiftUI

/// Installers: the list from Mole's own menu (`mo installer --dry-run` in a PTY), then the menu
/// driver selects exactly the chosen files and checks Mole's removal list before confirming.
/// `MOLE_DELETE_MODE=trash` sends them to the Trash instead of deleting them.
@MainActor @Observable
final class InstallersModel {
    struct File: Identifiable, Hashable {
        let name: String
        let sizeText: String
        let source: String
        var id: String { name + "|" + source }
        var size: Int64 { MoleSize.parse(sizeText) ?? 0 }
    }

    var stage: FlowStage = .start
    var files: [File] = []
    var selected: Set<String> = []
    var error: String?
    var resultHeadline = ""
    var resultLines: [String] = []
    var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private var scanGeneration = UUID()

    static let trashEnvironment = ["MOLE_DELETE_MODE": "trash"]

    var selectedSize: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan(_ app: AppModel) {
        guard stage != .scanning, stage != .running else { return }
        let generation = UUID()
        scanGeneration = generation
        error = nil
        stage = .scanning
        task = Task(.installers) {
            do {
                let (rows, _) = try await app.drive(["installer", "--dry-run"]) { session in
                    try InstallerDriver().list(in: session)
                }
                guard generation == scanGeneration else { return }
                try Task.checkCancellation()
                files = rows.map { File(name: $0.name, sizeText: $0.size, source: $0.source) }
                selected = Set(files.map(\.id))
                stage = .review
            } catch is CancellationError {
                guard generation == scanGeneration else { return }
                stage = .start
            } catch {
                guard generation == scanGeneration else { return }
                self.error = error.localizedDescription
                stage = .start
            }
        }
    }

    func remove(_ app: AppModel) {
        guard stage == .review else { return }
        let chosen = files.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        // Each file with the folder and size it was listed with, so a same-named file elsewhere, or
        // a different file behind the same cut name, never stands in.
        let targets = chosen.map { InstallerTarget(name: $0.name, sources: [$0.source], size: $0.sizeText) }
        stage = .running
        task = Task(.installers) {
            do {
                let (_, result) = try await app.drive(["installer"], environment: Self.trashEnvironment) { session in
                    try InstallerDriver().delete(targets, in: session)
                }
                resultLines = MoleSummary.lines(result.text)
                failed = !result.succeeded
                resultHeadline = failed ? String(localized: "Removal did not finish")
                    : String(localized: "Installer command finished; check the Trash for moved files")
            } catch is CancellationError {
                failed = true
                resultHeadline = String(localized: "Removal stopped")
                resultLines = [String(localized: "Files moved before the stop are in the Trash.")]
            } catch let refusal as InstallerDriverError {
                // The driver refuses before the final Enter, so nothing was touched.
                failed = true
                resultHeadline = String(localized: "Nothing was removed")
                resultLines = [Self.describe(refusal)]
            } catch {
                // After the confirmation some files may already be in the Trash.
                failed = true
                resultHeadline = String(localized: "Removal did not finish")
                resultLines = [error.localizedDescription, String(localized: "Check the Trash and the console for what was moved.")]
            }
            stage = .done
        }
    }

    func stop() {
        task?.cancel()
        // Keep busy until the cancelled task exits; a replacement must not overlap it.
    }
    func reset() {
        guard stage != .running, stage != .scanning else { return }
        scanGeneration = UUID(); task?.cancel(); error = nil
        stage = .start; files = []; selected = [] }

    /// Why the driver stopped before the final confirmation, in words. Nothing was touched.
    static func describe(_ refusal: InstallerDriverError) -> String {
        switch refusal {
        case .targetNotListed(let name):
            String(localized: "\(name) is no longer in Mole's list. Scan again.")
        case .targetListedTwice(let name):
            String(localized: "Mole lists \(name) twice, so Nora cannot tell which file you chose.")
        case .sourceNotAllowed(let name, let source):
            String(localized: "\(name) is now listed from another folder (\(source)). Scan again.")
        case .targetChanged(let name):
            String(localized: "\(name) changed since the scan. Scan again.")
        case .preselected:
            String(localized: "Mole had files selected in advance, so Nora stopped.")
        case .paginated:
            String(localized: "Mole's list is longer than one screen. Remove fewer installers at once.")
        case .selectionMismatch, .reviewMismatch:
            String(localized: "Mole's confirmation did not match your choice, so Nora cancelled it.")
        }
    }
}

struct InstallersView: View {
    @Environment(AppModel.self) private var app
    private var model: InstallersModel { app.installers }
    private let module = Module.installers

    var body: some View {
        switch model.stage {
        case .start:
            ModuleStart(module: module,
                        subtitle: "Disk images and installers you no longer need. They go to the Trash, so you can get them back.",
                        features: [Feature(symbol: "arrow.down.circle", text: "Downloads and Desktop"),
                                   Feature(symbol: "mug", text: "Homebrew cache"),
                                   Feature(symbol: "icloud", text: "iCloud, Mail and Telegram")],
                        command: "mo installer --dry-run",
                        action: { model.scan(app) }) {
                if let error = model.error { Notice(text: error, color: Palette.crit) }
            }
            .task { if app.autoScan { model.scan(app) } }
        case .scanning:
            WorkingView(module: module, title: "Looking for installers…", detail: String(localized: ".dmg, .pkg, .zip, .iso and .xip files"), onStop: { model.stop() })
        case .review:
            review
        case .running:
            WorkingView(module: module, title: "Moving installers to the Trash…", onStop: { model.stop() })
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) { model.reset() }
        }
    }

    private var review: some View {
        @Bindable var model = model
        return ModuleScene(module: module, leading: .startOver { model.reset() },
                           orb: OrbAction(title: "Remove", destructive: true, enabled: !model.selected.isEmpty, disabledReason: String(localized: "Select installers to remove"), action: { model.remove(app) })) {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(module: module, title: "Review installers",
                       subtitle: String(localized: "\(Format.bytes(model.selectedSize)) selected")) {
                SelectAllButton(ids: model.files.map(\.id), selection: $model.selected)
            }
            if model.files.isEmpty {
                Text("No installer files found.").font(.system(size: 15)).foregroundStyle(Palette.fg2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.files) { file in
                            CheckRow(isOn: Binding(get: { model.selected.contains(file.id) },
                                                   set: { if $0 { model.selected.insert(file.id) } else { model.selected.remove(file.id) } }),
                                     title: file.name, detail: file.source, size: file.size, tint: module.palette.glow)
                            Divider().overlay(Palette.line)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel()
            }
            ReviewFooter(command: "MOLE_DELETE_MODE=trash mo installer", note: String(localized: "Files go to the Trash. Nora checks Mole's list before it confirms."))
        }
        .padding(.horizontal, 34).padding(.top, 8)
        }
    }
}
