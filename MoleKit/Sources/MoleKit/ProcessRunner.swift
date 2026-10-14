import Foundation

/// The outcome of a command run in pipe mode: stdout and stderr are kept apart.
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// A command line as Nora shows it before running it, so every action stays visible.
public struct ShellCommand: Sendable, Hashable, CustomStringConvertible {
    public let executable: String
    public let arguments: [String]
    public var environment: [String: String] = [:]

    public init(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// `mo clean --dry-run`, quoting arguments that need it.
    public var description: String {
        let name = (executable as NSString).lastPathComponent
        let env = environment.keys.sorted().map { "\($0)=\(Self.quote(environment[$0] ?? ""))" }
        return (env + [name] + arguments.map(Self.quote)).joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,~"))
        if s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Every child started without a terminal, so quitting Nora can stop them. A scanner left
/// running after Nora is gone keeps a core busy for hours and nobody reads its result.
public enum ChildProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]
    nonisolated(unsafe) private static var shuttingDown = false
    nonisolated(unsafe) private static var groups: Set<pid_t> = []

    public static func register(_ process: Process) {
        lock.withLock { running[ObjectIdentifier(process)] = process }
    }

    public static func unregister(_ process: Process) {
        lock.withLock { _ = running.removeValue(forKey: ObjectIdentifier(process)) }
    }

    /// A PTY child leads its own session, so it is signalled as a process group: sudo, askpass
    /// and Mole's helpers stop with it.
    /// The group stays registered after its leader exits, while a helper may still run in it,
    /// and is dropped once empty: a process group id cannot be reused while any member lives, so
    /// a registered id never points at someone else's processes.
    public static func registerGroup(_ leader: pid_t) {
        lock.withLock { _ = groups.insert(leader) }
    }

    public static func unregisterGroup(_ leader: pid_t) {
        lock.withLock { _ = groups.remove(leader) }
    }

    /// Foundation starts a pipe child as the leader of its own process group (pgid == pid, seen
    /// on macOS 27), and `Process.terminate()` signals that group. Registering the group lets the
    /// quit barrier wait for helpers that outlive the leader. Call right after `run()`.
    static func adoptGroup(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 0, getpgid(pid) == pid { registerGroup(pid) }
    }

    /// After the leader exited: a stopped run's group gets SIGTERM, then SIGKILL after `grace`,
    /// and this returns once the group is empty, so a caller that restores state next never does
    /// it under a helper that is still working. A finished run's group stays registered until
    /// its last helper is gone.
    static func settleGroup(_ pid: pid_t, stopped: Bool, grace: TimeInterval = 2) {
        guard lock.withLock({ groups.contains(pid) }) else { return }
        if stopped, groupAlive(pid) {
            kill(-pid, SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while Date() < deadline, groupAlive(pid) { usleep(50_000) }
            if groupAlive(pid) {
                kill(-pid, SIGKILL)
                let hard = Date().addingTimeInterval(1)
                while Date() < hard, groupAlive(pid) { usleep(20_000) }
            }
        }
        guard groupAlive(pid) else { return unregisterGroup(pid) }
        DispatchQueue.global(qos: .utility).async {
            while groupAlive(pid) { usleep(200_000) }
            unregisterGroup(pid)
        }
    }

    /// SIGTERM to a registered group whose leader may already be gone.
    static func signalGroup(_ pid: pid_t) {
        if pid > 0, lock.withLock({ groups.contains(pid) }) { kill(-pid, SIGTERM) }
    }

    /// True while any process is left in the group (ESRCH means it is empty).
    public static func groupAlive(_ leader: pid_t) -> Bool {
        kill(-leader, 0) == 0 || errno == EPERM
    }

    /// True once Nora is quitting: a child that starts after the sweep is stopped right away.
    public static var isShuttingDown: Bool { lock.withLock { shuttingDown } }

    /// Sends SIGTERM to every child that is still running. The list is taken under the lock and
    /// the signals are sent after it is released, because termination handlers take the same lock.
    public static func terminateAll() {
        let (children, leaders) = lock.withLock { () -> ([Process], [pid_t]) in
            shuttingDown = true
            return (Array(running.values), Array(groups))
        }
        for child in children where child.isRunning { child.terminate() }
        for leader in leaders { kill(-leader, SIGTERM) }
    }

    /// The quit barrier: stops every child and its whole group, SIGKILL after `grace`. Returns
    /// false if something survived; the caller then leaves the whitelist overlay in place (more
    /// protection, put back at the next launch) instead of restoring it under a live run.
    @discardableResult
    public static func terminateAllAndWait(grace: TimeInterval = 3) -> Bool {
        terminateAll()
        if waitUntilGone(Date().addingTimeInterval(grace)) { return true }
        let (children, leaders) = lock.withLock { (Array(running.values), Array(groups)) }
        for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        for leader in leaders { kill(-leader, SIGKILL) }
        return waitUntilGone(Date().addingTimeInterval(1))
    }

    private static func waitUntilGone(_ deadline: Date) -> Bool {
        while true {
            let (children, leaders) = lock.withLock { (Array(running.values), Array(groups)) }
            if !children.contains(where: \.isRunning) && !leaders.contains(where: groupAlive) { return true }
            guard Date() < deadline else { return false }
            usleep(50_000)
        }
    }

    /// Call right after `run()`: stops a child that was launched after Nora began quitting or
    /// after its task was cancelled.
    static func stopIfUnwanted(_ process: Process, cancelled: Bool) {
        if (cancelled || isShuttingDown), process.isRunning { process.terminate() }
    }
}

/// Runs commands without a terminal. Prompting commands go through `PTYSession` instead.
public enum ProcessRunner {
    /// Runs to completion. Cancelling the task sends SIGTERM to the child. Long scans pass
    /// `.utility` so they yield the CPU to whatever the user is doing.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        qos: QualityOfService = .default
    ) async throws -> CommandResult {
        let process = makeProcess(executable, arguments, environment, currentDirectory)
        process.qualityOfService = qos
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outBuffer = DataBuffer(), errBuffer = DataBuffer()
        out.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }
        let stopped = Flag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { finished in
                    ChildProcesses.unregister(finished)
                    // Before reading to the end: a helper still holding the pipe would block it.
                    ChildProcesses.settleGroup(finished.processIdentifier, stopped: stopped.isSet)
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outBuffer.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: CommandResult(
                        status: ProcessFailure.status(of: finished),
                        stdout: outBuffer.string,
                        stderr: errBuffer.string
                    ))
                }
                // A task cancelled before the launch never starts the child.
                guard !Task.isCancelled else {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Registered before run, so a child that exits at once is still removed.
                ChildProcesses.register(process)
                do {
                    try process.run()
                    ChildProcesses.adoptGroup(process)
                    if Task.isCancelled { stopped.set() }
                    ChildProcesses.stopIfUnwanted(process, cancelled: Task.isCancelled)
                } catch {
                    ChildProcesses.unregister(process)
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            stopped.set()
            if process.isRunning { process.terminate() } else { ChildProcesses.signalGroup(process.processIdentifier) }
        }
    }

    /// Streams stdout line by line (NDJSON, console output). stderr lines arrive with `isError`.
    /// Ending the iteration or cancelling the task terminates the child.
    public static func lines(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        qos: QualityOfService = .default
    ) -> AsyncThrowingStream<OutputLine, Error> {
        AsyncThrowingStream { continuation in
            let process = makeProcess(executable, arguments, environment, nil)
            process.qualityOfService = qos
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let outSplitter = LineSplitter { continuation.yield(OutputLine(text: $0, isError: false)) }
            let errSplitter = LineSplitter { continuation.yield(OutputLine(text: $0, isError: true)) }
            out.fileHandleForReading.readabilityHandler = { outSplitter.feed($0.availableData) }
            err.fileHandleForReading.readabilityHandler = { errSplitter.feed($0.availableData) }

            let ended = Flag()
            process.terminationHandler = { finished in
                ChildProcesses.unregister(finished)
                ChildProcesses.settleGroup(finished.processIdentifier, stopped: ended.isSet)
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outSplitter.feed(out.fileHandleForReading.readDataToEndOfFile())
                errSplitter.feed(err.fileHandleForReading.readDataToEndOfFile())
                outSplitter.flush()
                errSplitter.flush()
                let status = ProcessFailure.status(of: finished)
                if status != 0 {
                    continuation.finish(throwing: ProcessFailure(status: status))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                ended.set()
                if process.isRunning { process.terminate() } else { ChildProcesses.signalGroup(process.processIdentifier) }
            }
            ChildProcesses.register(process)
            do {
                try process.run()
                ChildProcesses.adoptGroup(process)
                // The consumer may have gone away while the child was starting.
                ChildProcesses.stopIfUnwanted(process, cancelled: ended.isSet)
            } catch {
                ChildProcesses.unregister(process)
                continuation.finish(throwing: error)
            }
        }
    }

    static func makeProcess(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ cwd: URL?) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        return process
    }
}

/// A one-way switch shared between a stream's termination handler and its producer.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

public struct OutputLine: Sendable, Equatable {
    public let text: String
    public let isError: Bool
}

public struct ProcessFailure: Error, CustomStringConvertible, Equatable {
    public let status: Int32
    public var description: String { "exited with status \(status)" }

    /// The exit code, or 128 + the signal number for a child killed by a signal (the shell's
    /// convention), so a killed run never reads as a success.
    static func status(of process: Process) -> Int32 {
        process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    }
}

/// Thread-safe byte accumulator for pipe readability handlers.
final class DataBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Splits a byte stream into UTF-8 lines; carriage returns from progress output are dropped.
final class LineSplitter: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let emit: @Sendable (String) -> Void

    init(_ emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func feed(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\r", with: ""))
            pending.removeSubrange(pending.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }
}
