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
    var selection: Module = .status
    var showConsole = false
    let console = ConsoleLog()
    let status = StatusStore()

    let home = FileManager.default.homeDirectoryForCurrentUser

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

    /// Runs a Mole command in pipe mode and records it in the console.
    func run(_ arguments: [String], environment: [String: String] = [:]) async throws -> CommandResult {
        guard let mole else { throw NoraError.moleMissing }
        let entry = console.begin(mole.command(arguments, environment: environment))
        do {
            let result = try await mole.run(arguments, environment: environment)
            console.finish(entry, result: result)
            return result
        } catch {
            console.fail(entry, error: error)
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

    func begin(_ command: ShellCommand) -> UUID {
        let entry = Entry(command: command.description)
        entries.append(entry)
        if entries.count > 60 { entries.removeFirst(entries.count - 60) }
        return entry.id
    }

    func append(_ id: UUID, _ lines: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].output.append(contentsOf: lines)
        if entries[i].output.count > maxLines { entries[i].output.removeFirst(entries[i].output.count - maxLines) }
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
