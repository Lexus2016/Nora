import MoleKit
import Observation
import SwiftUI

/// Protection: Mole's own config files, edited natively.
/// - Cleanup: `~/.config/mole/whitelist`. While the file does not exist Mole applies its optional
///   defaults; any written file replaces them, so Nora always writes the defaults back in.
/// - Maintenance: `~/.config/mole/whitelist_optimize`, one task id per line.
/// - Project folders: `~/.config/mole/purge_paths`, one folder per line (`~` allowed).
@MainActor @Observable
final class ProtectionModel {
    enum Tab: String, CaseIterable { case cleanup, maintenance, projects }

    var tab: Tab = .cleanup
    var defaults: [String] = []
    var custom: [String] = []
    var cleanFileExists = false
    var tasks: [(name: String, id: String)] = []
    var excludedTasks: Set<String> = []
    var projectFolders: [String] = []
    var projectFileExists = false
    var newPattern = ""
    var message: String?
    var loaded = false
    private(set) var cleanupReady = false
    /// Lines of whitelist_optimize that are not task ids Nora knows (custom paths, newer ids).
    /// They are written back unchanged.
    private var optimizeOther: [String] = []
    /// True during an exclusive run or while recovery of its whitelist is pending.
    private var cleanListBusy: () -> Bool = { false }

    /// Injected in regression tests; the production writer remains atomic.
    @ObservationIgnored private let persist: (URL, String) throws -> Void

    init(write: @escaping (URL, String) throws -> Void = { url, text in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }) {
        persist = write
    }

    private var configDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole") }
    var cleanURL: URL { configDir.appendingPathComponent("whitelist") }
    var optimizeURL: URL { configDir.appendingPathComponent("whitelist_optimize") }
    var purgeURL: URL { configDir.appendingPathComponent("purge_paths") }
    /// Older Mole versions kept maintenance exclusions here; still read when the new file is absent.
    var legacyOptimizeURL: URL { configDir.appendingPathComponent("whitelist_checks") }

    func load(_ app: AppModel) {
        cleanListBusy = { [weak app] in app?.exclusiveRunActive ?? false }
        loaded = false
        cleanupReady = false
        guard !cleanListLocked(), let mole = app.mole else { return }
        guard loadDefaults({ try mole.installation.cleanWhitelistDefaults(home: app.home) }) else { return }
        let cleanLines: [String]?
        do {
            cleanLines = try Self.readCleanLines(app.overlay.whitelistURL)
        } catch {
            cleanupReady = false
            message = error.localizedDescription
            return
        }
        cleanFileExists = cleanLines != nil
        let home = app.home.path
        let expand: (String) -> String = { $0.hasPrefix("~/") ? home + $0.dropFirst(1) : $0 }
        let defaultSet = Set(defaults.map(expand))
        custom = (cleanLines ?? []).filter { !defaultSet.contains(expand($0)) }
        do {
            tasks = try mole.installation.optimizeTasks(home: app.home)
            let optimizeLines = try Self.readCleanLines(optimizeURL) ?? Self.readCleanLines(legacyOptimizeURL) ?? []
            let known = Set(tasks.map(\.id))
            excludedTasks = Set(optimizeLines.filter(known.contains))
            optimizeOther = optimizeLines.filter { !known.contains($0) }
            let purge = try Self.readCleanLines(purgeURL)
            projectFileExists = purge != nil
            projectFolders = purge ?? []
        } catch {
            cleanupReady = false
            message = error.localizedDescription
            return
        }
        loaded = true
    }

    /// A failed defaults read must never turn a first edit into an empty-default whitelist.
    @discardableResult
    func loadDefaults(_ read: () throws -> [String]) -> Bool {
        cleanupReady = false
        loaded = false
        do {
            defaults = try read()
            cleanupReady = true
            message = nil
            return true
        } catch {
            message = String(localized: "Protection could not load Mole's defaults. Editing is disabled; retry loading. \(error.localizedDescription)")
            return false
        }
    }

    /// Only an absent file means defaults apply. Unreadable files must block editing.
    static func readCleanLines(_ url: URL) throws -> [String]? {
        do {
            return lines(text: try String(contentsOf: url, encoding: .utf8))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    static func lines(text: String?) -> [String]? {
        guard let text else { return nil }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// A Cleanup or Projects run puts the whitelist back byte for byte when it ends, so an edit
    /// made meanwhile would be lost. The list waits until the run is over.
    private func cleanListLocked() -> Bool {
        guard cleanListBusy() else { return false }
        message = String(localized: "A cleaning task is running. Change this list when it finishes.")
        return true
    }

    func addPattern(_ pattern: String) {
        guard loaded, cleanupReady, !cleanListLocked() else { return }
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !custom.contains(p), !defaults.contains(p) else { return }
        let previous = custom
        custom.append(p)
        if !saveClean() { custom = previous }
    }

    func removePattern(_ pattern: String) {
        guard loaded, cleanupReady, !cleanListLocked() else { return }
        let previous = custom
        custom.removeAll { $0 == pattern }
        if !saveClean() { custom = previous }
    }

    private func saveClean() -> Bool {
        guard cleanupReady else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let body = (defaults + custom).map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        guard write(cleanURL, header: "# Protected from mo clean. Written by Nora: Mole's optional defaults are kept at the top.", lines: body) else { return false }
        cleanFileExists = true
        return true
    }

    /// One write for a bulk change instead of one per task.
    func setAllTasks(included: Set<String>) {
        guard loaded, !cleanListLocked() else { return }
        let previous = excludedTasks
        excludedTasks = Set(tasks.map(\.id)).subtracting(included)
        if !saveOptimize() { excludedTasks = previous }
    }

    func setTask(_ id: String, excluded: Bool) {
        guard loaded, !cleanListLocked() else { return }
        let previous = excludedTasks
        if excluded { excludedTasks.insert(id) } else { excludedTasks.remove(id) }
        if !saveOptimize() { excludedTasks = previous }
    }

    private func saveOptimize() -> Bool {
        write(optimizeURL, header: "# Tasks mo optimize skips. Written by Nora; other lines are kept.",
              lines: tasks.map(\.id).filter(excludedTasks.contains) + optimizeOther)
    }

    func addProjectFolder(_ path: String) {
        guard loaded, !cleanListLocked() else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        guard !projectFolders.contains(p) else { return }
        let previous = projectFolders
        projectFolders.append(p)
        if !savePurge() { projectFolders = previous }
    }

    func removeProjectFolder(_ path: String) {
        guard loaded, !cleanListLocked() else { return }
        let previous = projectFolders
        projectFolders.removeAll { $0 == path }
        if !savePurge() { projectFolders = previous }
    }

    private func savePurge() -> Bool {
        guard write(purgeURL, header: "# Mole Purge Paths, edited in Nora. One folder per line, ~ for the home folder.", lines: projectFolders) else { return false }
        projectFileExists = true
        return true
    }

    private func write(_ url: URL, header: String, lines: [String]) -> Bool {
        do {
            try persist(url, ([header, ""] + lines).joined(separator: "\n") + "\n")
            message = String(localized: "Saved to \((url.path as NSString).abbreviatingWithTildeInPath)")
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

struct ProtectionView: View {
    @Environment(AppModel.self) private var app
    private var model: ProtectionModel { app.protection }
    private let module = Module.protection

    var body: some View {
        @Bindable var model = model
        ModuleScene(module: module) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    Glass3D(name: module.glass, size: 110, glow: module.palette.glow, amplitude: 0)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(module.title).font(.system(size: 44, weight: .light))
                        Text("What Mole must never touch. Changes are saved at once to Mole's own settings files.")
                            .font(.system(size: 15)).foregroundStyle(Palette.fg2)
                    }
                    Spacer()
                }
                Picker("", selection: $model.tab) {
                    Text("Cleanup").tag(ProtectionModel.Tab.cleanup)
                    Text("Maintenance").tag(ProtectionModel.Tab.maintenance)
                    Text("Project folders").tag(ProtectionModel.Tab.projects)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 460)
                Group {
                    switch model.tab {
                    case .cleanup: cleanup
                    case .maintenance: maintenance
                    case .projects: projects
                    }
                }
                .disabled(!model.loaded)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
                .glassPanel(radius: 20)
                if !model.loaded { Button("Retry") { model.load(app) }.buttonStyle(GlassButtonStyle()) }
                if let message = model.message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
            .padding(.horizontal, 34).padding(.top, 6)
        }
        .task { if !app.isVisualSnapshot && !model.loaded { model.load(app) } }
    }

    private var cleanup: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Path or pattern, e.g. ~/Library/Caches/com.example.app", text: $model.newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addPattern(model.newPattern); model.newPattern = "" }
                Button("Add") { model.addPattern(model.newPattern); model.newPattern = "" }.buttonStyle(GlassButtonStyle())
                Button("Choose folder…") { if let path = Self.chooseFolder() { model.addPattern(path) } }.buttonStyle(GlassButtonStyle())
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.custom, id: \.self) { pattern in
                        row(pattern, badge: nil) { model.removePattern(pattern) }
                    }
                    ForEach(model.defaults, id: \.self) { pattern in
                        row(pattern, badge: String(localized: "Mole default"), remove: nil)
                    }
                }
            }
            Text("Mole's built-in safety rules (system fonts, Spotlight, iCloud and more) always apply on top of this list.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }

    private var maintenance: some View {
        VStack(alignment: .trailing, spacing: 10) {
            SelectAllButton(ids: model.tasks.map(\.id), selection: Binding(
                get: { Set(model.tasks.map(\.id)).subtracting(model.excludedTasks) },
                set: { included in model.setAllTasks(included: included) }))
            maintenanceList
        }
    }

    private var maintenanceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.tasks, id: \.id) { task in
                    Toggle(isOn: Binding(get: { !model.excludedTasks.contains(task.id) }, set: { model.setTask(task.id, excluded: !$0) })) {
                        HStack {
                            Text(OptimizeText.title(task.name)).font(.system(size: 14, weight: .medium))
                            Spacer()
                            Text(task.id).font(.mono).foregroundStyle(Palette.muted)
                        }
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .padding(.vertical, 6)
                    Divider().overlay(Palette.line)
                }
            }
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.projectFileExists ? "Mole scans these folders for old build folders." : "Mole finds project folders on its own. Add a folder to set the list yourself.")
                    .font(.system(size: 13)).foregroundStyle(Palette.fg2)
                Spacer()
                Button("Add folder…") { if let path = Self.chooseFolder() { model.addProjectFolder(path) } }.buttonStyle(GlassButtonStyle())
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.projectFolders, id: \.self) { folder in
                        row(folder, badge: nil) { model.removeProjectFolder(folder) }
                    }
                }
            }
        }
    }

    private func row(_ text: String, badge: String?, remove: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: badge == nil ? module.symbol : "lock").foregroundStyle(module.palette.glow)
            Text(text).font(.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            if let badge { Text(badge).font(.system(size: 11)).foregroundStyle(Palette.muted) }
            if let remove {
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Palette.fg2).help(Text("Remove"))
            }
        }
        .padding(.vertical, 6)
    }

    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
