import MoleKit
import SwiftUI

/// Homebrew casks with a newer version: checkboxes, and a footer with the exact upgrade command.
/// Update runs that command, and only the selected casks are upgraded.
struct AppsUpdates: View {
    @Bindable var model: AppsModel
    @Environment(AppModel.self) private var app
    private let module = Module.applications

    var body: some View {
        ModuleScene(module: module, leading: .back { model.back() },
                    orb: model.selectedUpdates.isEmpty ? nil : OrbAction(title: "Update", action: { model.upgrade(app) })) {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(module: module, title: "Updates",
                       subtitle: String(localized: "\(model.updates.count) Homebrew apps have a newer version"))
            if let note = model.updatesNote { Notice(text: note, symbol: "info.circle", color: Palette.muted) }
            if model.updates.isEmpty {
                Text("Every Homebrew app is up to date.").font(.system(size: 15)).foregroundStyle(Palette.fg2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.updates) { update in
                            CheckRow(isOn: binding(update.token), title: update.name,
                                     detail: detail(update), tint: module.palette.glow)
                            Divider().overlay(Palette.line)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel()
            }
            ReviewFooter(command: command,
                         note: String(localized: "Only apps installed with Homebrew are listed. Nothing else is updated."))
        }
        .padding(.horizontal, 34).padding(.top, 8)
        }
    }

    private func binding(_ token: String) -> Binding<Bool> {
        Binding(get: { model.selectedUpdates.contains(token) },
                set: { if $0 { model.selectedUpdates.insert(token) } else { model.selectedUpdates.remove(token) } })
    }

    private func detail(_ update: Homebrew.Update) -> String {
        let versions = "\(update.installed) → \(update.latest)"
        return update.autoUpdates ? String(localized: "\(versions) · updates itself") : versions
    }

    /// The command Update will run, or a hint while nothing is selected.
    private var command: String {
        guard let path = Homebrew.executable(),
              let shell = Homebrew.upgradeCommand(tokens: model.selectedTokens, executable: path)
        else { return String(localized: "Select apps to see the command.") }
        return shell.description
    }
}
