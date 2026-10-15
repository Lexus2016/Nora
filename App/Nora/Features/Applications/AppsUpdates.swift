import MoleKit
import SwiftUI

/// Apps with a newer version: Homebrew casks, then apps from a download. Checkboxes for what
/// Update can install, an Open button for apps that update themselves, and a footer with the
/// exact commands. Update installs only the selected apps.
struct AppsUpdates: View {
    @Bindable var model: AppsModel
    @Environment(AppModel.self) private var app
    private let module = Module.applications

    var body: some View {
        ModuleScene(module: module, leading: .back { model.back() },
                    orb: model.selectedUpdates.isEmpty ? nil : OrbAction(title: "Update", action: { model.requestUpgrade(app) })) {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(module: module, title: "Updates",
                       subtitle: String(localized: "\(model.updateCount) apps have a newer version")) {
                SelectAllButton(ids: model.updatableIDs, selection: $model.selectedUpdates)
            }
            if let note = model.updatesNote { Notice(text: note, symbol: "info.circle", color: Palette.muted) }
            if model.updateCount == 0 {
                Text("Every app is up to date.").font(.system(size: 15)).foregroundStyle(Palette.fg2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.updates) { update in
                            CheckRow(isOn: binding(update.token), title: update.name,
                                     detail: detail(update), tint: module.palette.glow)
                            Divider().overlay(Palette.line)
                        }
                        ForEach(model.outside) { update in
                            if update.token != nil {
                                CheckRow(isOn: binding(update.path), title: update.name,
                                         detail: String(localized: "\(update.installed) → \(update.latest) · Homebrew will install it"),
                                         tint: module.palette.glow)
                            } else {
                                openRow(update)
                            }
                            Divider().overlay(Palette.line)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel()
            }
            ReviewFooter(command: command,
                         note: String(localized: "Only the selected apps are updated. An app from a download goes to the Trash first and comes back if Homebrew fails."))
        }
        .padding(.horizontal, 34).padding(.top, 8)
        }
        .alert("Quit the open apps?", isPresented: Binding(get: { model.askingToQuit }, set: { model.askingToQuit = $0 })) {
            Button("Quit and update") { model.upgrade(app) }
            Button("Cancel", role: .cancel) { model.cancelQuit() }
        } message: {
            Text("Open now: \(Array(Set(model.openToQuit.map(\.name))).sorted().formatted(.list(type: .and))). Nora quits them, updates them and opens them again. Each app can ask you to save your work first.")
        }
    }

    /// An app Nora cannot install: opening it lets its own updater do the job.
    private func openRow(_ update: OutsideApps.Update) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(update.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(String(localized: "\(update.installed) → \(update.latest) · open it and check for updates in its menu"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: update.path)) }.buttonStyle(GlassButtonStyle())
        }
        .padding(.leading, 20).padding(.vertical, 3)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selectedUpdates.contains(id) },
                set: { if $0 { model.selectedUpdates.insert(id) } else { model.selectedUpdates.remove(id) } })
    }

    private func detail(_ update: Homebrew.Update) -> String {
        let versions = "\(update.installed) → \(update.latest)"
        return update.autoUpdates ? String(localized: "\(versions) · updates itself") : versions
    }

    /// The commands Update will run, or a hint while nothing is selected.
    private var command: String {
        // One command per app, run in turn, so Stop can wait for the app in progress.
        guard let path = Homebrew.executable(), !model.selectedUpdates.isEmpty else { return String(localized: "Select apps to see the command.") }
        let upgrades = model.selectedTokens.compactMap { Homebrew.upgradeCommand(tokens: [$0], executable: path)?.description }
        let installs = model.selectedOutside.compactMap { item in
            item.token.flatMap { Homebrew.installCommand(token: $0, executable: path)?.description }
        }
        return (upgrades + installs).joined(separator: "; ")
    }
}
