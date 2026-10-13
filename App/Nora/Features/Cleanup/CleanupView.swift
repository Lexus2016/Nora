import MoleKit
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var app
    @State private var model = CleanupModel()
    private let module = Module.cleanup

    var body: some View {
        switch model.stage {
        case .start:
            start
                .task { if app.autoScan { model.scan(app) } }
        case .scanning:
            WorkingView(module: module, title: "Looking for what can be cleaned…", lines: app.console.entries.last?.output ?? [],
                        onStop: { model.stop() })
        case .review:
            CleanupReview(model: model)
        case .running:
            WorkingView(module: module, title: "Cleaning…", lines: app.console.entries.last?.output ?? [])
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) { model.reset() }
        }
    }

    private var start: some View {
        @Bindable var model = model
        return ModuleStart(module: module,
                        subtitle: "Caches, logs and leftovers of removed apps. You see every path before anything is deleted.",
                        bullets: ["App and browser caches, logs, developer tool caches",
                                  "Files left behind by apps you already removed",
                                  "Uncheck anything you want to keep: Nora protects it for this run"],
                        command: model.previewCommand,
                        action: { model.scan(app) }) {
                Toggle("Include system caches (asks for your password)", isOn: $model.includeSystem)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                if let error = model.error { Notice(text: error, color: Palette.crit) }
            }
    }
}

private struct CleanupReview: View {
    @Bindable var model: CleanupModel
    @Environment(AppModel.self) private var app
    @State private var expanded: Set<String> = []
    private let module = Module.cleanup

    var body: some View {
        let preview = model.preview
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(module: module, title: "Review cleanup",
                       subtitle: String(localized: "\(Format.bytes(model.selectedSize)) selected"),
                       back: { model.reset() })
            if let preview {
                notes(preview)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(preview.sections, id: \.self) { section in
                            sectionRows(section)
                            Divider().overlay(Palette.line)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel()
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    CommandPreview(command: model.command)
                    Text(model.protectedCount > 0
                         ? String(localized: "\(model.protectedCount) unchecked items stay protected for this run. Caches and logs are deleted permanently; apps recreate them.")
                         : String(localized: "Caches and logs are deleted permanently; apps recreate them."))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Clean \(Format.bytes(model.selectedSize))") { model.clean(app) }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(model.selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
    }

    @ViewBuilder private func notes(_ preview: CleanPreview) -> some View {
        let shown = preview.notes.filter { !$0.text.localizedCaseInsensitiveContains("need sudo") }.prefix(4)
        if preview.needsSudoForSystem || !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if preview.needsSudoForSystem && !model.includeSystem {
                    HStack {
                        Notice(text: String(localized: "System caches are not included. They need your password."), symbol: "lock")
                        Button("Include them") { model.includeSystem = true; model.scan(app) }.buttonStyle(.link)
                    }
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, note in
                    if note.text.localizedCaseInsensitiveContains("Full Disk Access") && !app.hasFullDiskAccess {
                        HStack {
                            Notice(text: String(localized: "\(note.text.components(separatedBy: " · ").first ?? note.section): skipped until Nora has Full Disk Access."), symbol: "lock.shield")
                            Button("Open settings") { Permissions.openFullDiskAccess() }.buttonStyle(.link)
                        }
                    } else {
                        Notice(text: "\(note.section): \(note.text)", symbol: "info.circle", color: Palette.fg2)
                    }
                }
            }
        }
    }

    @ViewBuilder private func sectionRows(_ section: String) -> some View {
        let items = model.items(in: section)
        let selectedCount = items.filter { model.selected.contains($0.path) }.count
        let size = items.reduce(Int64(0)) { $0 + $1.size }
        let isExpanded = expanded.contains(section)
        HStack(spacing: 10) {
            Button {
                if isExpanded { expanded.remove(section) } else { expanded.insert(section) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 16, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Palette.fg2)
            Toggle(isOn: Binding(get: { selectedCount == items.count }, set: { model.setSection(section, on: $0) })) {
                HStack {
                    Text(section).font(.system(size: 14, weight: .medium))
                    Text("\(selectedCount) of \(items.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(Format.bytes(size)).font(.system(size: 13, design: .rounded)).monospacedDigit()
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(.vertical, 6)
        if isExpanded {
            ForEach(items) { item in
                CheckRow(isOn: Binding(get: { model.selected.contains(item.path) },
                                       set: { if $0 { model.selected.insert(item.path) } else { model.selected.remove(item.path) } }),
                         title: (item.path as NSString).lastPathComponent,
                         detail: (item.path as NSString).abbreviatingWithTildeInPath,
                         size: item.size, tint: module.palette.glow)
                    .padding(.leading, 26)
            }
        }
    }
}

enum Permissions {
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func openAutomation() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
