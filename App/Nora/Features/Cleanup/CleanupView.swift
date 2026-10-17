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
                        detail: WorkingView.currentItem(app.console.output(of: module)) ?? String(localized: "Caches, logs and leftovers of removed apps"),
                        onStop: { model.stop() })
        case .review:
            if model.showList { CleanupList(model: model) } else { CleanupResults(model: model) }
        case .running:
            WorkingView(module: module, title: "Cleaning…", detail: WorkingView.currentItem(app.console.output(of: module)), onStop: { model.stop() })
        case .done:
            VStack {
                if model.recoveryRequired {
                    Button("Retry protection recovery") { model.retryRecovery(app) }.buttonStyle(.bordered)
                }
                DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) { model.reset() }
            }
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
                    orb: OrbAction(title: "Clean", enabled: model.canClean,
                                   disabledReason: String(localized: "Select items from a complete scan to clean."), action: { model.clean(app) })) {
            VStack(spacing: 22) {
                ResultHeadline(text: String(localized: "Your Mac has \(Format.bytes(model.preview?.items.reduce(0) { $0 + $1.addedSize } ?? 0)) of junk."),
                               button: ("Review all junk", { model.openList(nil) }))
                CleanupNotes(model: model)
                if sections.isEmpty {
                    Text("Nothing to clean right now.").font(.system(size: 16)).foregroundStyle(Palette.fg2).frame(maxHeight: .infinity)
                } else {
                    GeometryReader { geo in
                        HStack(alignment: .top, spacing: 18) {
                            // Keep localized details above the decorative artwork. At short
                            // window heights the complete card, including its actions, scrolls.
                            ScrollView {
                                card(sections[0], large: true).frame(height: max(420, geo.size.height))
                            }
                            .frame(width: max(320, (geo.size.width - 36) / 3))
                            ScrollView {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 18)], spacing: 18) {
                                    ForEach(sections.dropFirst(), id: \.self) { card($0).frame(height: max(200, (geo.size.height - 18) / 2)) }
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
        return CategoryCard(value: model.sizeText(section),
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
            let shown = model.reviewNotes
            VStack(alignment: .leading, spacing: 6) {
                if preview.needsSudoForSystem && !model.includeSystem {
                    HStack {
                        Notice(text: String(localized: "System caches are not included. They need your password."), symbol: "lock")
                        Button("Include them") { model.includeSystem = true; model.scan(app) }.buttonStyle(.link)
                    }
                }
                ForEach(Array(shown.prefix(3).enumerated()), id: \.offset) { _, note in
                    noteRow(note)
                }
                if shown.count > 3 {
                    DisclosureGroup("More scan notes") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(shown.dropFirst(3).enumerated()), id: \.offset) { _, note in
                                    noteRow(note)
                                }
                            }
                        }.frame(maxHeight: 160)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func noteRow(_ note: CleanPreview.Note) -> some View {
        HStack {
            Notice(text: note.text, symbol: "exclamationmark.circle")
            if note.text.localizedCaseInsensitiveContains("Full Disk Access") {
                Button("Open settings") { Permissions.openFullDiskAccess() }.buttonStyle(.link)
            }
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
        // One category on screen cleans that category only; hidden ticks never ride along.
        let scoped = model.listSection.map { model.selected(in: $0) }
        let size = scoped?.size ?? model.selectedSize
        let canClean = scoped.map { !$0.paths.isEmpty } ?? !model.selected.isEmpty
        ModuleScene(module: module, leading: .back { model.showList = false },
                    orb: OrbAction(title: "Clean", enabled: canClean && model.canClean,
                                   disabledReason: String(localized: "Select items from a complete scan to clean."), action: {
                        if let section = model.listSection { model.clean(section: section, app) } else { model.clean(app) }
                    })) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(module: module,
                           title: model.listSection.map { LocalizedStringKey(CleanSection($0).title) } ?? "All junk",
                           subtitle: String(localized: "\(Format.bytes(size)) selected")) {
                    SelectAllButton(ids: sections.flatMap { model.items(in: $0).map(\.path) }, selection: $model.selected)
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
                    Text(model.sizeText(section)).font(.system(size: 13, design: .rounded)).monospacedDigit()
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
                         size: item.sizeKnown ? item.size : nil,
                         sizeNote: item.sizeKnown ? nil : String(localized: "size unknown"), tint: module.palette.glow)
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
