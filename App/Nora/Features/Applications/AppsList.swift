import MoleKit
import SwiftUI

/// The full app list with search, icons, last-used dates, sizes and checkboxes. Filtered to the
/// unused apps when opened from the results card.
struct AppsList: View {
    @Bindable var model: AppsModel
    @Environment(AppModel.self) private var app
    private let module = Module.applications

    var body: some View {
        ModuleScene(module: module, leading: .back { model.back() },
                    orb: model.selected.isEmpty ? nil : OrbAction(title: "Uninstall", destructive: true, action: { model.review(app) })) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                GlassImage(name: module.glass, size: 72, glow: module.palette.glow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.listFilter == .unused ? "Unused apps" : module.title)
                        .font(.system(size: 32, weight: .light)).shadow(color: module.palette.glow.opacity(0.5), radius: 12)
                    Text("Removes an app together with its helpers, caches and settings. Personal data stays.")
                        .font(.system(size: 13)).foregroundStyle(Palette.fg2)
                }
                Spacer()
                SelectAllButton(ids: model.visible.map(\.path), selection: $model.selected)
                TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if model.listFilter == .unused {
                HStack(spacing: 10) {
                    Notice(text: String(localized: "Not opened for 90 days or more. \(model.visible.count) apps."), symbol: "clock.arrow.circlepath", color: Palette.muted)
                    Button("Show all apps") { model.listFilter = .all }.buttonStyle(.link)
                }
            }
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
                Text(lastOpened(item)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).frame(width: 150, alignment: .trailing)
                Text(model.sizes[item.path].map(Format.bytes) ?? "…").font(.system(size: 12, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.fg2).frame(width: 80, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 5)
    }

    private func lastOpened(_ item: InstalledApp) -> String {
        guard let date = model.lastUsed[item.path] else { return String(localized: "Last opened unknown") }
        return String(localized: "Opened \(date.formatted(date: .abbreviated, time: .omitted))")
    }
}

/// The uninstall preview: every item Mole would remove, per app. Uninstall stays disabled until
/// the preview has been read.
struct AppsReview: View {
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
