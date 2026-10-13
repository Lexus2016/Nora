import AppKit
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
    var selection: Module = .smartCare
    /// Debug launch arguments for screenshots and checks: `-NoraModule cleanup -NoraAutoScan 1`.
    let autoScan: Bool

    init() {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "NoraModule"), let module = Module(rawValue: name) { selection = module }
        autoScan = UserDefaults.standard.bool(forKey: "NoraAutoScan")
        #else
        autoScan = false
        #endif
        if !selection.isAvailable { selection = Module.available.first ?? .status }
    }
    var showConsole = false {
        // The console covers the orb; an invisible orb must not take clicks meant for it.
        didSet { orb.hidden = showConsole; orb.updateHitArea() }
    }
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

    let home = FileManager.default.homeDirectoryForCurrentUser

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

    /// One Cleanup or Projects run at a time, from its fresh check until the whitelist is put
    /// back: a second run would read the first one's temporary protection as the user's choice.
    @ObservationIgnored private var exclusiveRun: String?

    func beginExclusiveRun(_ id: String) -> Bool {
        guard exclusiveRun == nil, !overlay.needsRecovery else { return false }
        exclusiveRun = id
        return true
    }

    func endExclusiveRun(_ id: String) {
        if exclusiveRun == id { exclusiveRun = nil }
    }

    /// A preview taken now would not see what the running task protects for itself.
    var exclusiveRunActive: Bool { exclusiveRun != nil || overlay.needsRecovery }

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

    /// Prepares the askpass helper and undoes a whitelist overlay left by a crash.
    func prepare() {
        try? PrivilegeBroker.writeDialogAskpass(
            to: askpassURL,
            message: String(localized: "Nora needs your Mac password for this Mole command. Nora does not see or store it."),
            cancel: String(localized: "Cancel"),
            ok: String(localized: "OK"))
        try? overlay.recoverIfNeeded()
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
    /// non-zero exit.
    func stream(_ command: ShellCommand, environment: [String: String]) async throws {
        let id = console.begin(command)
        do {
            for try await line in ProcessRunner.lines(URL(fileURLWithPath: command.executable), command.arguments, environment: environment) {
                console.append(id, [ANSI.strip(line.text)])
            }
            console.finish(id, status: 0)
        } catch let failure as ProcessFailure {
            console.finish(id, status: failure.status)
            throw failure
        } catch {
            console.fail(id, error: error)
            throw error
        }
    }

    /// Runs a Mole command in a PTY (prompts, same-tty sudo), mirroring the screen into the console.
    func runPTY(_ arguments: [String], sudo: Bool = false, environment: [String: String] = [:]) async throws -> PTYRun.Result {
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
            if case .exited(let code) = result.status { console.finish(id, status: code) } else { console.finish(id, status: -1) }
            return result
        } catch {
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
        guard let mole else { throw NoraError.moleMissing }
        var env = mole.environment.merging(userEnvironment) { $1 }.merging(environment) { $1 }
        if sudo { env = PrivilegeBroker.environment(env, askpass: askpassURL) }
        let id = console.begin(mole.command(arguments, environment: environment), prefix: sudo ? "sudo -A -v && " : "")
        let console = self.console
        do {
            let outcome = try await PTYRun.drive(executable: mole.executable.path, arguments: arguments, environment: env, sudo: sudo,
                                                 onScreen: { lines in Task { @MainActor in console.mirror(id, lines) } }, driver)
            console.replace(id, outcome.result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            if case .exited(let code) = outcome.result.status { console.finish(id, status: code) } else { console.finish(id, status: -1) }
            return outcome
        } catch {
            console.fail(id, error: error)
            throw error
        }
    }

    /// Runs a Mole command in pipe mode, streaming its output into the console as it arrives.
    func run(_ arguments: [String], environment: [String: String] = [:]) async throws -> CommandResult {
        guard let mole else { throw NoraError.moleMissing }
        let id = console.begin(mole.command(arguments, environment: environment))
        var out: [String] = [], err: [String] = []
        var status: Int32 = 0
        do {
            for try await line in ProcessRunner.lines(mole.executable, arguments, environment: mole.environment.merging(userEnvironment) { $1 }.merging(environment) { $1 }) {
                if line.isError { err.append(line.text) } else { out.append(line.text) }
                console.append(id, [ANSI.strip(line.text)])
            }
        } catch let failure as ProcessFailure {
            status = failure.status
        } catch {
            console.fail(id, error: error)
            throw error
        }
        try Task.checkCancellation()
        console.finish(id, status: status)
        return CommandResult(status: status, stdout: out.joined(separator: "\n"), stderr: err.joined(separator: "\n"))
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

/// Every command Nora runs, with its exact command line and output.
@MainActor @Observable
final class ConsoleLog {
    struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let startedAt = Date()
        var output: [String] = []
        var status: Int32?
        var failure: String?
        var isRunning: Bool { status == nil && failure == nil }
    }

    private(set) var entries: [Entry] = []
    private let maxLines = 4000

    func begin(_ command: ShellCommand, prefix: String = "") -> UUID {
        let entry = Entry(command: prefix + command.description)
        entries.append(entry)
        if entries.count > 60 { entries.removeFirst(entries.count - 60) }
        return entry.id
    }

    func append(_ id: UUID, _ lines: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].output.append(contentsOf: lines)
        if entries[i].output.count > maxLines { entries[i].output.removeFirst(entries[i].output.count - maxLines) }
    }

    /// Shows the live PTY screen while the command runs.
    func mirror(_ id: UUID, _ lines: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].isRunning else { return }
        let trimmed = Array(lines.reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed())
        entries[i].output = trimmed
    }

    func replace(_ id: UUID, _ lines: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
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
        entries[i].status = status
    }

    func fail(_ id: UUID, error: Error) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].failure = error.localizedDescription
    }
}

enum ANSI {
    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
    }
}
