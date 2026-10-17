import AppKit
import Darwin
import Foundation
import MoleKit
import Observation

/// Root state shared by the window and the menu bar.
@MainActor @Observable
final class AppModel {
    enum MoleState {
        case locating
        case ready(Mole)
        case missing
        case unsupported(Mole)
        case broken(path: String, reason: String)
    }

    var moleState: MoleState = .locating
    var selection: Module = .smartCare {
        didSet { if selection != oldValue { showConsole = false } }
    }
    /// A module opened from a Smart Care tile. Its screens lead back to Smart Care instead of
    /// starting over, so the scan behind the tiles stays intact. Sidebar navigation preserves this return route.
    private(set) var reviewOrigin: Module?

    func reviewFromSmartCare(_ module: Module) {
        reviewOrigin = module
        if module == .cleanup { cleanup.showList = false; cleanup.listSection = nil }
        selection = module
    }
    /// Debug launch arguments for screenshots and checks: `-NoraModule cleanup -NoraAutoScan 1`.
    let autoScan: Bool

    /// Synthetic rendering only; release builds cannot enable this mode.
    let isVisualSnapshot: Bool

    init(visualSnapshot: Bool = false, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         trash: TrashReminderModel? = nil) {
        self.home = home
        #if DEBUG
        isVisualSnapshot = visualSnapshot
        if let name = UserDefaults.standard.string(forKey: "NoraModule"), let module = Module(rawValue: name) { selection = module }
        autoScan = !visualSnapshot && UserDefaults.standard.bool(forKey: "NoraAutoScan")
        #else
        isVisualSnapshot = false
        autoScan = false
        #endif
        self.trash = trash ?? TrashReminderModel.live(visualSnapshot: isVisualSnapshot)
        self.trash.externalBlocker = { [weak self] in self?.trashBlocker }
        if !selection.isAvailable { selection = Module.available.first ?? .status }
    }
    var showConsole = false
    let console = ConsoleLog()
    let status = StatusStore()
    let orb = OrbController()
    let cleanup = CleanupModel()
    let projects = ProjectsModel()
    let installers = InstallersModel()
    let apps = AppsModel()
    let performance = PerformanceModel()
    let smartCare = SmartCareModel()
    let spaceMap = SpaceMapModel()
    let history = HistoryModel()
    let protection = ProtectionModel()
    let tools = ToolsModel()
    let security = SecurityModel()
    let trash: TrashReminderModel

    let home: URL

    /// `~/Library/Application Support/Nora`: askpass helper, whitelist journal, history.
    var supportDirectory: URL {
        let url = home.appendingPathComponent("Library/Application Support/Nora", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var askpassURL: URL { supportDirectory.appendingPathComponent("askpass.sh") }

    var overlay: WhitelistOverlay {
        WhitelistOverlay(home: home, journalURL: supportDirectory.appendingPathComponent("whitelist-journal.json"))
    }

    /// Apps in the Trash while Homebrew installs their new version (see `OutsideApps.Journal`).
    var handover: OutsideApps.Journal {
        OutsideApps.Journal(url: supportDirectory.appendingPathComponent("app-handover.json"))
    }

    /// One Cleanup or Projects run at a time, from its fresh check until the whitelist is put
    /// back: a second run would read the first one's temporary protection as the user's choice.
    @ObservationIgnored private var exclusiveRun: String?
    @ObservationIgnored private var protectionProbe: MoleProbeCancellation?

    func beginExclusiveRun(_ id: String) -> Bool {
        guard !trash.blocksOtherMutations, exclusiveRun == nil, !overlay.needsRecovery,
              protectionProbe?.canRestoreProtection != false else { return false }
        // Invalidate the editor's asynchronous snapshot even if this run starts and finishes
        // before that read returns; a transient overlay must never become editable user rules.
        protection.cancelLoad()
        exclusiveRun = id
        protectionProbe = MoleProbeCancellation()
        return true
    }

    func probeCancellation(for runID: String) throws -> MoleProbeCancellation {
        guard exclusiveRun == runID, let protectionProbe else { throw WhitelistOverlayError.pendingRecovery }
        return protectionProbe
    }

    func recoverProtection() throws {
        guard exclusiveRun == nil else { throw WhitelistOverlayError.pendingRecovery }
        guard protectionProbe?.canRestoreProtection != false else { throw MoleProbeError.unsettled }
        try overlay.recoverIfNeeded()
    }

    /// Both cleanup defers and manual recovery pass through the same settlement barrier.
    func recoverProtection(runID: String) throws {
        guard exclusiveRun == runID else { throw WhitelistOverlayError.pendingRecovery }
        guard protectionProbe?.canRestoreProtection != false else { throw MoleProbeError.unsettled }
        try overlay.recover(runID: runID)
    }

    func endExclusiveRun(_ id: String) {
        if exclusiveRun == id {
            exclusiveRun = nil
            if protectionProbe?.canRestoreProtection == true { protectionProbe = nil }
        }
    }

    /// Protects `paths` for one run through the whitelist overlay, then asks Mole whether each
    /// one really is protected. Mole's loader drops some literal names (one with `..` in it, a
    /// trailing space), and such a path would be removed although the user unticked it, so the
    /// run stops here instead. The caller's `recover(runID:)` takes the overlay off again.
    func protect(_ paths: [String], with mole: Mole, runID: String) async throws {
        let (overlay, installation, home) = (overlay, mole.installation, home)
        let cancellation = try probeCancellation(for: runID)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await Task.detached {
                try Self.protect(paths, overlay: overlay, installation: installation, home: home,
                                 runID: runID, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel() }
    }

    /// `protect` without the main actor, for drivers that decide inside a PTY session.
    nonisolated static func protect(_ paths: [String], overlay: WhitelistOverlay, installation: MoleInstallation,
                                    home: URL, runID: String, cancellation: MoleProbeCancellation) throws {
        try cancellation.checkCancellation()
        guard !paths.isEmpty else { return }
        let defaults = try installation.cleanWhitelistDefaults(home: home, cancellation: cancellation)
        try cancellation.checkCancellation()
        try overlay.apply(protecting: paths, defaults: defaults, runID: runID)
        let open = try installation.unprotected(paths, home: home, cancellation: cancellation)
        try cancellation.checkCancellation()
        if let first = open.first {
            let path = first.replacingOccurrences(of: home.path, with: "~", options: .anchored)
            throw NoraError.commandFailed(open.count == 1
                ? String(localized: "Mole cannot keep \(path) safe: its protection list does not accept that name. Nothing was removed. Tick it to remove it too, or rename it and scan again.")
                : String(localized: "Mole cannot keep \(path) and \(open.count - 1) more unticked items safe: its protection list does not accept those names. Nothing was removed. Tick them to remove them too, or rename them and scan again."))
        }
    }

    /// A preview taken now would not see what the running task protects for itself.
    var exclusiveRunActive: Bool {
        exclusiveRun != nil || overlay.needsRecovery || protectionProbe?.canRestoreProtection == false
    }

    static let trashBusyMessage = String(localized: "A Trash operation or recovery check is in progress. Try again when it finishes.")

    private var trashBlocker: TrashReminderBlock? {
        if exclusiveRunActive || Module.allCases.contains(where: { isBusy($0) })
            || tools.touchIDBusy || tools.updateBusy || tools.externalBusy || tools.externalCleaning
            || tools.completionBusy || tools.removeBusy || console.entries.contains(where: { $0.isRunning }) {
            return .busy(String(localized: "Another Nora operation is running. Try again when it finishes."))
        }
        do {
            if try hasPendingHandoverStrictly() {
                return .recovery(String(localized: "An app update needs recovery before the Trash can be emptied."))
            }
        } catch {
            return .recovery(String(localized: "An app update needs recovery before the Trash can be emptied."))
        }
        return nil
    }

    /// Absence is only ENOENT; unreadable paths, symlinks and corrupt journals block Trash.
    private func hasPendingHandoverStrictly() throws -> Bool {
        let url = home.appendingPathComponent("Library/Application Support/Nora/app-handover.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadNoPermission)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 16 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try file.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return !(try JSONDecoder().decode([OutsideApps.Journal.Entry].self, from: data)).isEmpty
    }

    static let busyScanMessage = String(localized: "A cleaning task is running. Scan again when it finishes.")

    /// Full Disk Access lets Mole clean the Trash and app containers. Mole runs as Nora's
    /// child, so the permission belongs to Nora.
    var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
            || FileManager.default.isReadableFile(atPath: home.appendingPathComponent("Library/Safari/Bookmarks.plist").path)
    }

    /// Set by the main window so the menu bar can reopen it after it was closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// SwiftUI's openSettings, captured from a view. Since macOS 14 the old
    /// `showSettingsWindow:` action is ignored, so AppKit menus go through this.
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    func showSettings() {
        NSApp.activate()
        openSettingsWindow?()
    }

    /// Brings the main window forward, optionally on a module.
    func showMain(_ module: Module?) {
        if let module, module.isAvailable { selection = module }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// Extra environment from Settings for every Mole command.
    var userEnvironment: [String: String] {
        var env: [String: String] = [:]
        if UserDefaults.standard.bool(forKey: "moleNoOpLog") { env["MO_NO_OPLOG"] = "1" }
        return env
    }

    /// Prepares the askpass helper and undoes what a crash left: a whitelist overlay, or an app
    /// waiting in the Trash for a Homebrew install that never finished.
    func prepare() {
        try? PrivilegeBroker.writeDialogAskpass(
            to: askpassURL,
            message: String(localized: "Nora needs your Mac password for this Mole command. Nora does not see or store it."),
            cancel: String(localized: "Cancel"),
            ok: String(localized: "OK"))
        do { try recoverProtection() }
        catch {
            cleanup.recoveryRequired = true
            cleanup.failed = true
            cleanup.resultHeadline = String(localized: "Recovery required")
            cleanup.resultLines = [CleanupModel.describe(error)]
            cleanup.stage = .done
        }
        handover.recover()
    }

    /// A module with a scan or a run in progress shows a ring on its rail icon.
    func isBusy(_ module: Module) -> Bool {
        let stage: FlowStage? = switch module {
        case .cleanup: cleanup.stage
        case .projects: projects.stage
        case .installers: installers.stage
        case .applications: apps.stage
        case .performance: performance.stage
        case .spaceMap: spaceMap.loading ? .scanning : spaceMap.stage
        case .security: security.stage
        case .smartCare: smartCare.phase == .scanning || smartCare.phase == .running ? .running : nil
        default: nil
        }
        return stage == .scanning || stage == .running
    }

    var mole: Mole? {
        if case .ready(let mole) = moleState { return mole }
        return nil
    }

    func locate() async {
        moleState = .locating
        let override = UserDefaults.standard.string(forKey: "molePath").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        switch await MoleLocator.locate(home: home, override: override) {
        case .found(let mole):
            moleState = mole.isSupported ? .ready(mole) : .unsupported(mole)
            if mole.isSupported { status.attach(mole) }
        case .missing:
            moleState = .missing
        case .broken(let path, let reason):
            moleState = .broken(path: path, reason: reason)
        }
    }

    /// Runs any command, streaming its output into the console. Throws `ProcessFailure` on a
    /// non-zero exit and `CancellationError` when its task was stopped.
    func stream(_ command: ShellCommand, environment: [String: String]) async throws {
        guard !trash.blocksOtherMutations else { throw NoraError.commandFailed(Self.trashBusyMessage) }
        let id = console.begin(command)
        do {
            for try await line in ProcessRunner.lines(URL(fileURLWithPath: command.executable), command.arguments, environment: environment) {
                console.append(id, [ANSI.strip(line.text)])
            }
        } catch let failure as ProcessFailure {
            try console.checkStopped(id)
            console.finish(id, status: failure.status)
            throw failure
        } catch {
            try console.checkStopped(id)
            console.fail(id, error: error)
            throw error
        }
        // A cancelled stream just ends: without this a stopped command would read as a success.
        try console.checkStopped(id)
        console.finish(id, status: 0)
    }

    /// Runs a Mole command in a PTY (prompts, same-tty sudo), mirroring the screen into the console.
    func runPTY(_ arguments: [String], sudo: Bool = false, environment: [String: String] = [:]) async throws -> PTYRun.Result {
        guard !trash.blocksOtherMutations else { throw NoraError.commandFailed(Self.trashBusyMessage) }
        guard let mole else { throw NoraError.moleMissing }
        var env = mole.environment.merging(userEnvironment) { $1 }.merging(environment) { $1 }
        if sudo { env = PrivilegeBroker.environment(env, askpass: askpassURL) }
        let shown = mole.command(arguments, environment: environment)
        let id = console.begin(shown, prefix: sudo ? "sudo -A -v && " : "")
        let console = self.console
        do {
            let result = try await PTYRun.run(executable: mole.executable.path, arguments: arguments, environment: env, sudo: sudo) { lines in
                Task { @MainActor in console.mirror(id, lines) }
            }
            console.replace(id, result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            try console.checkStopped(id)
            if case .exited(let code) = result.status { console.finish(id, status: code) } else { console.finish(id, status: -1) }
            return result
        } catch {
            try console.checkStopped(id)
            console.fail(id, error: error)
            throw error
        }
    }

    /// Runs a Mole command in a PTY with a driver answering its menus and prompts.
    func drive<T: Sendable>(
        _ arguments: [String],
        sudo: Bool = false,
        environment: [String: String] = [:],
        _ driver: @escaping @Sendable (PTYSession) throws -> T
    ) async throws -> (value: T, result: PTYRun.Result) {
        guard !trash.blocksOtherMutations else { throw NoraError.commandFailed(Self.trashBusyMessage) }
        guard let mole else { throw NoraError.moleMissing }
        var env = mole.environment.merging(userEnvironment) { $1 }.merging(environment) { $1 }
        if sudo { env = PrivilegeBroker.environment(env, askpass: askpassURL) }
        let id = console.begin(mole.command(arguments, environment: environment), prefix: sudo ? "sudo -A -v && " : "")
        let console = self.console
        do {
            let outcome = try await PTYRun.drive(executable: mole.executable.path, arguments: arguments, environment: env, sudo: sudo,
                                                 onScreen: { lines in Task { @MainActor in console.mirror(id, lines) } }, driver)
            console.replace(id, outcome.result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            try console.checkStopped(id)
            if case .exited(let code) = outcome.result.status { console.finish(id, status: code) } else { console.finish(id, status: -1) }
            return outcome
        } catch {
            // A stop ends the session under the driver, which then throws its own error: report
            // the stop, not that error.
            try console.checkStopped(id)
            console.fail(id, error: error)
            throw error
        }
    }

    /// Runs `mo <check>` and then `mo <run>` with administrator rights under one authentication in
    /// one PTY (`PrivilegeBroker.gated`). `decide` gets the check's output and exit status while
    /// the session waits; `run` starts only if it returns without throwing.
    func runGated(check: [String], run: [String],
                  decide: @escaping @Sendable (_ output: String, _ status: Int32) throws -> Void) async throws -> PTYRun.Result {
        guard !trash.blocksOtherMutations else { throw NoraError.commandFailed(Self.trashBusyMessage) }
        guard let mole else { throw NoraError.moleMissing }
        let env = PrivilegeBroker.environment(mole.environment.merging(userEnvironment) { $1 }, askpass: askpassURL)
        let (exe, args) = PrivilegeBroker.gated(executable: mole.executable.path, check: check, run: run)
        let id = console.begin(mole.command(run), prefix: "sudo -A -v && mo \(check.joined(separator: " ")) && ")
        let console = self.console
        do {
            let outcome = try await PTYRun.drive(wrapped: exe, arguments: args, environment: env,
                                                 onScreen: { lines in Task { @MainActor in console.mirror(id, lines) } }) { session in
                let marker = PrivilegeBroker.gateMarker + " "
                let screen = try session.waitUntil(timeout: 3600, "the check before the run") { $0.contains { $0.hasPrefix(marker) } }
                let status = screen.last { $0.hasPrefix(marker) }.flatMap { Int32($0.dropFirst(marker.count)) } ?? -1
                let output = TerminalText.render(session.transcriptBytes)
                try decide(String(output[..<(output.range(of: PrivilegeBroker.gateMarker)?.lowerBound ?? output.endIndex)]), status)
                try Task.checkCancellation()
                session.write("go\n")
            }
            console.replace(id, outcome.result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            try console.checkStopped(id)
            if case .exited(let code) = outcome.result.status { console.finish(id, status: code) } else { console.finish(id, status: -1) }
            return outcome.result.runPhaseResult()
        } catch {
            try console.checkStopped(id)
            console.fail(id, error: error)
            throw error
        }
    }

    /// Runs a Mole command in pipe mode, streaming its output into the console as it arrives.
    func run(_ arguments: [String], environment: [String: String] = [:]) async throws -> CommandResult {
        guard !trash.blocksOtherMutations else { throw NoraError.commandFailed(Self.trashBusyMessage) }
        guard let mole else { throw NoraError.moleMissing }
        let id = console.begin(mole.command(arguments, environment: environment))
        let console = self.console
        do {
            // Unlike cancelling an AsyncStream iterator, this awaits process-group settlement.
            let result = try await ProcessRunner.run(mole.executable, arguments,
                environment: mole.environment.merging(userEnvironment) { $1 }.merging(environment) { $1 },
                onOutput: { line in
                    Task { @MainActor in console.append(id, [ANSI.strip(line.text)]) }
                })
            let output = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
            console.replace(id, output.split(separator: "\n", omittingEmptySubsequences: false).map { ANSI.strip(String($0)) })
            try console.checkStopped(id)
            console.finish(id, status: result.status)
            return result
        } catch {
            try console.checkStopped(id)
            console.fail(id, error: error)
            throw error
        }
    }
}

enum NoraError: LocalizedError {
    case moleMissing
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .moleMissing: String(localized: "Mole is not installed.")
        case .commandFailed(let message): message
        }
    }
}

/// The module whose work runs the current task's commands. Start that work with
/// `Task(module) { … }` and its console entries carry the module, so its scene shows its own
/// command while another module runs one at the same time.
enum ConsoleOwner {
    @TaskLocal static var module: Module?
}

extension Task where Success == Void, Failure == Never {
    /// `@_implicitSelfCapture` is what the standard `Task.init` carries, so the bodies read the same.
    @discardableResult
    init(_ module: Module, @_implicitSelfCapture operation: sending @escaping @MainActor () async -> Void) {
        self.init { @MainActor in
            await ConsoleOwner.$module.withValue(module) { await operation() }
        }
    }
}

/// Every command Nora runs, with its exact command line and output.
@MainActor @Observable
final class ConsoleLog {
    struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let owner: Module?
        let startedAt = Date()
        var output: [String] = []
        var revision = 0
        var omittedLines = 0
        var status: Int32?
        var failure: String?
        var isRunning: Bool { status == nil && failure == nil }
    }

    private(set) var entries: [Entry] = []
    private let maxLines = 4000

    func begin(_ command: ShellCommand, prefix: String = "") -> UUID {
        let entry = Entry(command: prefix + command.description, owner: ConsoleOwner.module)
        entries.append(entry)
        if entries.count > 60 { entries.removeFirst(entries.count - 60) }
        return entry.id
    }

    /// The output of the module's latest command. Never another module's: two modules may run at once.
    func output(of module: Module) -> [String] {
        entries.last { $0.owner == module }?.output ?? []
    }

    /// Marks the entry as stopped and throws `CancellationError` when its task was cancelled.
    func checkStopped(_ id: UUID) throws {
        guard Task.isCancelled else { return }
        if let i = entries.firstIndex(where: { $0.id == id }), entries[i].isRunning {
            entries[i].failure = String(localized: "Stopped")
            entries[i].revision += 1
        }
        throw CancellationError()
    }

    func append(_ id: UUID, _ lines: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].isRunning else { return }
        entries[i].revision += 1
        entries[i].output.append(contentsOf: lines)
        if entries[i].output.count > maxLines {
            entries[i].omittedLines += entries[i].output.count - maxLines
            entries[i].output.removeFirst(entries[i].output.count - maxLines)
        }
    }

    /// Shows the live PTY screen while the command runs.
    func mirror(_ id: UUID, _ lines: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].isRunning else { return }
        let trimmed = Array(lines.reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed())
        entries[i].revision += 1
        entries[i].omittedLines = max(0, trimmed.count - maxLines)
        entries[i].output = Array(trimmed.suffix(maxLines))
    }

    func replace(_ id: UUID, _ lines: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].revision += 1
        entries[i].omittedLines = max(0, lines.count - maxLines)
        entries[i].output = Array(lines.suffix(maxLines))
    }

    func finish(_ id: UUID, result: CommandResult) {
        let lines = (result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr))
            .split(separator: "\n", omittingEmptySubsequences: false).map { ANSI.strip(String($0)) }
        append(id, lines)
        finish(id, status: result.status)
    }

    func finish(_ id: UUID, status: Int32) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].revision += 1
        entries[i].status = status
    }

    func fail(_ id: UUID, error: Error) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].revision += 1
        entries[i].failure = error.localizedDescription
    }
}

enum ANSI {
    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
    }
}
