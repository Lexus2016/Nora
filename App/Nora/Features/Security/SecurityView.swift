import MoleKit
import SwiftUI

/// Security: start → scanning → results → findings or quarantine list. Each step is a Nora scene.
struct SecurityView: View {
    let model: SecurityModel
    @Environment(AppModel.self) private var app
    private let module = Module.security

    var body: some View {
        Group {
            switch model.stage {
            case .start:
                SecurityStart(model: model)
            case .scanning:
                WorkingView(module: module, title: "Looking for signals…", detail: model.progress, onStop: { model.stop() })
            case .running:
                WorkingView(module: module, title: model.stopRequested ? "Finishing the current item…" : "Moving to quarantine…", detail: model.progress,
                            onStop: model.stopRequested ? nil : { model.stopAfterCurrent() })
            case .review, .done:
                if let mode = model.listMode {
                    SecurityList(model: model, mode: mode)
                } else {
                    SecurityResults(model: model)
                }
            }
        }
        .onAppear { model.refreshTools() }
        .task { await model.loadPreviewLaunchPaths() }
    }
}

private struct SecurityStart: View {
    let model: SecurityModel
    @Environment(AppModel.self) private var app
    private let module = Module.security

    var body: some View {
        @Bindable var model = model
        ModuleStart(module: module,
                    subtitle: "Checks launch items and their signatures, then runs Apple's XProtect rules and a ClamAV antivirus scan. Results are signals to review. Nothing is moved without your click.",
                    features: [Feature(symbol: "gearshape.2", text: "Launch items and their signatures"),
                               Feature(symbol: "shield.lefthalf.filled", text: "Apple XProtect rules"),
                               Feature(symbol: "ladybug", text: "ClamAV antivirus scan"),
                               Feature(symbol: "arrow.uturn.backward.circle", text: "Quarantine with one click back")],
                    command: model.scanCommand,
                    action: { model.scan(app) }) {
            Picker("Scope", selection: $model.scope) {
                ForEach(ScanScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            Text(model.scope.summary).font(.system(size: 13)).foregroundStyle(Palette.fg2)
            toolStatus
            if let notice = model.notice {
                Notice(text: notice, color: Palette.crit)
            }
        }
    }

    @ViewBuilder private var toolStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.clamav.isInstalled {
                Notice(text: String(localized: "ClamAV is not installed, so the antivirus scan is off."), symbol: "exclamationmark.shield")
                installButton(String(localized: "Install ClamAV with Homebrew"), formula: "clamav")
            } else if !model.databaseReady {
                Notice(text: String(localized: "ClamAV's virus database is not downloaded yet."), symbol: "arrow.down.circle")
                HStack(spacing: 10) {
                    Button("Update virus database") { model.updateDatabase(app) }.buttonStyle(GlassButtonStyle())
                        .disabled(model.updatingDatabase)
                    if model.updatingDatabase {
                        Spinner()
                        Text("Downloading the virus database…").font(.system(size: 12)).foregroundStyle(Palette.fg2)
                        Button("Cancel") { model.cancelSetup() }.buttonStyle(.link)
                    }
                }
            }
            if model.yaraMissing {
                Notice(text: String(localized: "yara is not installed, so Apple's XProtect rules do not run."), symbol: "exclamationmark.shield")
                installButton(String(localized: "Install with Homebrew"), formula: "yara")
            }
        }
    }

    @ViewBuilder private func installButton(_ title: String, formula: String) -> some View {
        if BrewTools.brew != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button(title) { model.install(formula, app) }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(model.installing != nil)
                    if model.installing == formula {
                        Spinner()
                        Text(model.downloadingDatabase ? "Downloading the virus database…" : "Installing…").font(.system(size: 12)).foregroundStyle(Palette.fg2)
                        Button("Cancel") { model.cancelSetup() }.buttonStyle(.link)
                    }
                }
                CommandPreview(command: "brew install \(formula)").frame(maxWidth: 420)
            }
        } else {
            HStack(spacing: 10) {
                Notice(text: String(localized: "Homebrew was not found. Install Homebrew first."))
                Link("brew.sh", destination: URL(string: "https://brew.sh")!).font(.system(size: 12, weight: .semibold))
            }
        }
    }
}

private struct SecurityResults: View {
    let model: SecurityModel
    @Environment(AppModel.self) private var app
    private let module = Module.security

    var body: some View {
        ModuleScene(module: module, leading: .startOver { model.reset() },
                    orb: model.checked.isEmpty ? nil : OrbAction(title: "Quarantine", action: { model.quarantineChecked(app) })) {
            VStack(spacing: 22) {
                ResultHeadline(text: headline, button: reviewAll)
                SecurityNotes(model: model)
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 18) {
                        launchCard.frame(width: (geo.size.width - 36) / 3)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                                xprotectCard.frame(height: 190)
                                clamavCard.frame(height: 190)
                                quarantineCard.frame(height: 190)
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 16).padding(.bottom, 6)
        }
    }

    private var headline: String {
        if !model.findings.isEmpty { return String(localized: "\(model.findings.count) signals to review.") }
        // An unfinished antivirus pass found nothing only in the files it could read.
        return model.clamavIncomplete
            ? String(localized: "The antivirus scan did not finish, so this result is incomplete.")
            : String(localized: "Nothing to review in this scan.")
    }

    private var reviewAll: (LocalizedStringKey, () -> Void)? {
        model.findings.isEmpty ? nil : ("Review all", { model.openList(.findings) })
    }

    private var launchCard: some View {
        CategoryCard(value: "\(model.launchItems.count)",
                     caption: String(localized: "launch items checked"),
                     detail: String(localized: "\(model.launchFlagged) to review"),
                     symbol: "gearshape.2", tint: module.palette.glow, large: true, glass: module.glass,
                     review: { model.openList(.findings) })
    }

    private var xprotectCard: some View {
        let state = model.xprotect
        let value: String
        let detail: String
        var actionTitle: LocalizedStringKey?
        var action: (() -> Void)?
        if model.yaraMissing {
            value = String(localized: "Unavailable")
            detail = String(localized: "yara is not installed, so Apple's XProtect rules do not run.")
            actionTitle = "Install with Homebrew"
            if BrewTools.brew != nil { action = { model.install("yara", app) } }
        } else if model.rulesMissing {
            value = String(localized: "Unavailable")
            detail = String(localized: "Apple's XProtect rules were not found on this Mac.")
        } else {
            switch state {
            case .notRun:
                value = "–"
                detail = String(localized: "Runs with the next scan.")
            case .ran(let matches):
                value = "\(matches)"
                detail = String(localized: "Matches of Apple's XProtect rules.")
            case .partial(let matches, let message):
                value = matches == 0 ? String(localized: "Failed") : "\(matches)"
                detail = String(localized: "Some folders could not be checked: \(message)")
            }
        }
        return CategoryCard(value: value, caption: String(localized: "XProtect rules"), detail: detail,
                            symbol: "shield.lefthalf.filled", tint: module.palette.glow,
                            actionTitle: actionTitle, review: { model.openList(.findings) }, action: action)
    }

    private var clamavCard: some View {
        let value: String
        let detail: String
        var actionTitle: LocalizedStringKey?
        var action: (() -> Void)?
        if !model.clamav.isInstalled {
            value = String(localized: "Not installed")
            detail = String(localized: "The antivirus scan needs ClamAV from Homebrew.")
            actionTitle = "Install ClamAV with Homebrew"
            if BrewTools.brew != nil { action = { model.install("clamav", app) } }
        } else if !model.databaseReady {
            value = String(localized: "No database")
            detail = String(localized: "Download the virus database before scanning.")
            actionTitle = "Update database"
            action = { model.updateDatabase(app) }
        } else {
            value = "\(model.clamavSignals)"
            detail = model.clamavIncomplete ? String(localized: "The ClamAV scan did not finish.") : String(localized: "ClamAV signatures matched.")
        }
        return CategoryCard(value: value, caption: String(localized: "ClamAV signals"), detail: detail,
                            symbol: "ladybug", tint: module.palette.glow,
                            actionTitle: actionTitle, review: { model.openList(.findings) }, action: action)
    }

    private var quarantineCard: some View {
        CategoryCard(value: "\(model.quarantine.count)",
                     caption: String(localized: "items in quarantine"),
                     detail: String(localized: "Restore or delete them here."),
                     symbol: "tray.full", tint: module.palette.glow,
                     review: { model.openList(.quarantine) })
    }
}

/// Permissions and errors under the results headline.
private struct SecurityNotes: View {
    let model: SecurityModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.scope == .full && !app.hasFullDiskAccess {
                HStack {
                    Notice(text: String(localized: "Without Full Disk Access, macOS hides parts of your home folder from Nora."), symbol: "hand.raised")
                    Button("Open settings") { Permissions.openFullDiskAccess() }.buttonStyle(.link)
                }
            }
            if model.skippedICloud > 0 {
                Notice(text: String(localized: "Skipped \(model.skippedICloud) iCloud folders. Their files are placeholders until downloaded."),
                       symbol: "icloud.slash")
            }
            if model.unreadableCount > 0 {
                Notice(text: String(localized: "\(model.unreadableCount) items could not be read and were not scanned."), symbol: "eye.slash")
            }
            if let notice = model.notice {
                Notice(text: notice, color: Palette.crit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// The detailed lists: findings with checkboxes, or the quarantine.
private struct SecurityList: View {
    let model: SecurityModel
    let mode: SecurityModel.ListMode
    @Environment(AppModel.self) private var app
    @State private var pendingDelete: QuarantineEntry?
    private let module = Module.security

    var body: some View {
        let title: LocalizedStringKey = mode == .findings ? "Signals to review" : "Quarantine"
        let orb: OrbAction? = (mode == .findings && !model.checked.isEmpty)
            ? OrbAction(title: "Quarantine", action: { model.quarantineChecked(app) })
            : nil
        ModuleScene(module: module, leading: .back { model.listMode = nil }, orb: orb) {
            VStack(alignment: .leading, spacing: 14) {
                StepHeader(module: module, title: title, subtitle: subtitle) {
                    if mode == .findings {
                        SelectAllButton(ids: model.findings.filter(\.canQuarantine).map(\.id), selection: Bindable(model).checked)
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rows
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassPanel()
                footer
            }
            .padding(.horizontal, 34).padding(.top, 8)
        }
        .confirmationDialog("Delete this file permanently?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                if let entry = pendingDelete { model.deletePermanently(entry) }
                pendingDelete = nil
            }
        } message: {
            Text("The file is removed from disk and cannot be restored.")
        }
    }

    private var subtitle: String? {
        switch mode {
        case .findings: String(localized: "Nothing is selected. Tick what you want to move to quarantine.")
        case .quarantine: String(localized: "Restore brings a file back to its original place.")
        }
    }

    @ViewBuilder private var rows: some View {
        switch mode {
        case .findings:
            if model.findings.isEmpty {
                Text("Nothing to review.").font(.system(size: 14)).foregroundStyle(Palette.fg2).padding(.vertical, 12)
            }
            ForEach(model.findings) { finding in
                FindingRow(model: model, finding: finding)
                Divider().overlay(Palette.line)
            }
        case .quarantine:
            if model.quarantine.isEmpty {
                Text("Nothing in quarantine.").font(.system(size: 14)).foregroundStyle(Palette.fg2).padding(.vertical, 12)
            }
            ForEach(model.quarantine) { entry in
                QuarantineRow(model: model, entry: entry, onDelete: { pendingDelete = entry })
                Divider().overlay(Palette.line)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch mode {
        case .findings:
            ReviewFooter(command: model.quarantineCommand,
                         note: String(localized: "Quarantine moves each ticked file into Nora's folder. Restore brings it back in one click."))
        case .quarantine:
            ReviewFooter(command: nil,
                         note: String(localized: "Restoring does not load a launch agent again. It starts at the next login or when you load it yourself."))
        }
    }
}

private struct FindingRow: View {
    let model: SecurityModel
    let finding: SecurityFinding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if finding.canQuarantine {
                Toggle("", isOn: Binding(
                    get: { model.checked.contains(finding.id) },
                    set: { on in
                        if on { model.checked.insert(finding.id) } else { model.checked.remove(finding.id) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.top, 2)
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 16)
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.source.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                Text(finding.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(finding.path)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
                ForEach(finding.reasons, id: \.self) { reason in
                    Label { Text(reason) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.warn)
                        .lineLimit(3)
                }
                if !finding.canQuarantine {
                    Text("Needs an administrator to change. Nora leaves it alone.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

private struct QuarantineRow: View {
    let model: SecurityModel
    let entry: QuarantineEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.fileName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Text(entry.originalPath)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(1).truncationMode(.middle)
            Text(entry.detection)
                .font(.system(size: 12))
                .foregroundStyle(Palette.warn)
                .lineLimit(2)
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                Button("Restore") { model.restore(entry) }.buttonStyle(GlassButtonStyle())
                Button("Delete permanently", action: onDelete).buttonStyle(DestructiveButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}
