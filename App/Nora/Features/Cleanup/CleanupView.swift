import MoleKit
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var app
    private var model: CleanupModel { app.cleanup }
    private let module = Module.cleanup

    var body: some View {
        switch model.stage {
        case .start:
            start.task { if app.autoScan { model.scan(app) } }
        case .scanning:
            WorkingView(module: module, title: "Looking for junk…",
                        detail: WorkingView.currentItem(app.console.entries.last?.output ?? []) ?? String(localized: "Caches, logs and leftovers of removed apps"),
                        onStop: { model.stop() })
        case .review:
            if model.showList { CleanupList(model: model) } else { CleanupResults(model: model) }
        case .running:
            WorkingView(module: module, title: "Cleaning…", detail: WorkingView.currentItem(app.console.entries.last?.output ?? []))
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) { model.reset() }
        }
    }

    private var start: some View {
        @Bindable var model = model
        return ModuleStart(module: module,
                           subtitle: "Remove caches, logs and leftovers to free space. You see every item before anything is deleted.",
                           features: [Feature(symbol: "archivebox", text: "App and system caches"),
                                      Feature(symbol: "globe", text: "Browser data"),
                                      Feature(symbol: "hammer", text: "Developer tool caches"),
                                      Feature(symbol: "puzzlepiece", text: "Leftovers of removed apps")],
                           command: model.previewCommand,
                           action: { model.scan(app) }) {
            Toggle("Include system caches (asks for your password)", isOn: $model.includeSystem)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
            if let error = model.error { Notice(text: error, color: Palette.crit) }
        }
    }
}

/// Results: one sentence, then a card per Mole section with Review and Clean.
private struct CleanupResults: View {
    @Bindable var model: CleanupModel
    @Environment(AppModel.self) private var app
    private let module = Module.cleanup

    var body: some View {
        let sections = model.rankedSections
        ModuleScene(module: module, leading: .startOver { model.reset() },
                    orb: model.selected.isEmpty ? nil : OrbAction(title: "Clean", action: { model.clean(app) })) {
            VStack(spacing: 22) {
                ResultHeadline(text: String(localized: "Your Mac has \(Format.bytes(model.selectedSize)) of junk."),
                               button: ("Review all junk", { model.openList(nil) }))
                CleanupNotes(model: model)
                if sections.isEmpty {
                    Text("Nothing to clean right now.").font(.system(size: 16)).foregroundStyle(Palette.fg2).frame(maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        HStack(alignment: .top, spacing: 18) {
                            card(sections[0], large: true).frame(width: (geo.size.width - 36) / 3)
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                                    ForEach(sections.dropFirst(), id: \.self) { card($0).frame(height: max(170, (geo.size.height - 18) / 2)) }
                                }
                            }
                            .scrollIndicators(.never)
                        }
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 16).padding(.bottom, 6)
        }
    }

    private func card(_ section: String) -> some View { card(section, large: false) }

    private func card(_ section: String, large: Bool) -> some View {
        let info = CleanSection(section)
        return CategoryCard(value: Format.bytes(model.sectionSize(section)),
                            caption: info.title.prefix(1).uppercased() + info.title.dropFirst(),
                            detail: large ? info.detail : nil,
                            symbol: info.symbol, tint: module.palette.glow, large: large, glass: large ? module.glass : nil,
                            actionTitle: "Clean",
                            review: { model.openList(section) },
                            action: { model.clean(section: section, app) })
    }
}

/// Permission and sudo notes under the results headline.
private struct CleanupNotes: View {
    @Bindable var model: CleanupModel
    @Environment(AppModel.self) private var app

    var body: some View {
        if let preview = model.preview {
            let shown = preview.notes.filter { !$0.text.localizedCaseInsensitiveContains("need sudo") }.prefix(3)
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
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// The detailed list: every path with a checkbox, for one section or all of them.
private struct CleanupList: View {
    @Bindable var model: CleanupModel
    @Environment(AppModel.self) private var app
    @State private var expanded: Set<String> = []
    private let module = Module.cleanup

    var body: some View {
        let sections = model.listSection.map { [$0] } ?? model.rankedSections
        ModuleScene(module: module, leading: .back { model.showList = false },
                    orb: model.selected.isEmpty ? nil : OrbAction(title: "Clean", action: { model.clean(app) })) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(module: module,
                           title: model.listSection.map { LocalizedStringKey(CleanSection($0).title) } ?? "All junk",
                           subtitle: String(localized: "\(Format.bytes(model.selectedSize)) selected")) {
                    SelectAllButton(ids: sections.flatMap { model.items(in: $0).map(\.path) }, selection: $model.selected)
                }
                if let section = model.listSection {
                    let others = model.otherSelected(than: section)
                    if !others.titles.isEmpty {
                        Notice(text: String(localized: "Clean also cleans the other ticked categories: \(others.titles.joined(separator: ", ")) (\(Format.bytes(others.size)))."),
                               symbol: "exclamationmark.triangle")
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.self) { section in
                            sectionRows(section, open: model.listSection != nil)
                            Divider().overlay(Palette.line)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel()
                ReviewFooter(command: model.command,
                             note: model.protectedCount > 0
                                ? String(localized: "\(model.protectedCount) unchecked items stay protected for this run. Caches and logs are deleted permanently; apps recreate them.")
                                : String(localized: "Caches and logs are deleted permanently; apps recreate them."))
            }
            .padding(.horizontal, 34).padding(.top, 8)
        }
    }

    @ViewBuilder private func sectionRows(_ section: String, open: Bool) -> some View {
        let items = model.items(in: section)
        let selectedCount = items.filter { model.selected.contains($0.path) }.count
        let isExpanded = open || expanded.contains(section)
        HStack(spacing: 10) {
            if !open {
                Button { if isExpanded { expanded.remove(section) } else { expanded.insert(section) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 16, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Palette.fg2)
            }
            Toggle(isOn: Binding(get: { selectedCount == items.count }, set: { model.setSection(section, on: $0) })) {
                HStack {
                    Text(CleanSection(section).title).font(.system(size: 14, weight: .medium))
                    Text("\(selectedCount) of \(items.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(Format.bytes(model.sectionSize(section))).font(.system(size: 13, design: .rounded)).monospacedDigit()
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
                    .padding(.leading, open ? 0 : 26)
            }
        }
    }
}

/// Mole's section names with a friendlier title, a symbol and a line of explanation.
struct CleanSection {
    let title: String
    let symbol: String
    let detail: String?

    init(_ name: String) {
        switch name {
        case "User essentials":
            title = String(localized: "your app caches and logs"); symbol = "person.crop.circle"
            detail = String(localized: "Caches and logs that apps create as they run. They come back as needed.")
        case "App caches":
            title = String(localized: "system app caches"); symbol = "square.stack.3d.up"
            detail = String(localized: "Caches of Apple and third-party services such as Maps and media.")
        case "Browsers":
            title = String(localized: "browser caches"); symbol = "globe"
            detail = String(localized: "Shader, GPU and update caches of your browsers. History and passwords stay.")
        case "Developer tools":
            title = String(localized: "developer tool caches"); symbol = "hammer"
            detail = String(localized: "npm, pip, Cargo, Go, Xcode and other tool caches. They download again when needed.")
        case "Apps & utilities":
            title = String(localized: "app data"); symbol = "app.badge"
            detail = String(localized: "Caches of apps like Slack and DaVinci Resolve.")
        case "Application Support":
            title = String(localized: "Application Support"); symbol = "folder"
            detail = String(localized: "Logs and caches kept inside Application Support.")
        case "Cloud & Office":
            title = String(localized: "cloud and office caches"); symbol = "icloud"; detail = nil
        case "App leftovers":
            title = String(localized: "leftovers of removed apps"); symbol = "puzzlepiece"
            detail = String(localized: "Files of apps that are no longer installed.")
        case "Virtualization":
            title = String(localized: "virtualization caches"); symbol = "server.rack"; detail = nil
        case "System":
            title = String(localized: "system caches"); symbol = "gearshape.2"
            detail = String(localized: "System-wide caches and logs. Needs your password.")
        default:
            title = name; symbol = "sparkles"; detail = nil
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
