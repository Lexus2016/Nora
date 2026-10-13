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

    public static func register(_ process: Process) {
        lock.withLock { running[ObjectIdentifier(process)] = process }
    }

    public static func unregister(_ process: Process) {
        lock.withLock { _ = running.removeValue(forKey: ObjectIdentifier(process)) }
    }

    /// Sends SIGTERM to every child that is still running.
    public static func terminateAll() {
        lock.withLock { running.values.filter(\.isRunning).forEach { $0.terminate() } }
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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                process.terminationHandler = { finished in
                    ChildProcesses.unregister(finished)
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outBuffer.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: CommandResult(
                        status: finished.terminationStatus,
                        stdout: outBuffer.string,
                        stderr: errBuffer.string
                    ))
                }
                // Registered before run, so a child that exits at once is still removed.
                ChildProcesses.register(process)
                do { try process.run() } catch {
                    ChildProcesses.unregister(process)
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
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

            process.terminationHandler = { finished in
                ChildProcesses.unregister(finished)
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outSplitter.feed(out.fileHandleForReading.readDataToEndOfFile())
                errSplitter.feed(err.fileHandleForReading.readDataToEndOfFile())
                outSplitter.flush()
                errSplitter.flush()
                if finished.terminationReason == .exit, finished.terminationStatus != 0 {
                    continuation.finish(throwing: ProcessFailure(status: finished.terminationStatus))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            ChildProcesses.register(process)
            do { try process.run() } catch {
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

public struct OutputLine: Sendable, Equatable {
    public let text: String
    public let isError: Bool
}

public struct ProcessFailure: Error, CustomStringConvertible, Equatable {
    public let status: Int32
    public var description: String { "exited with status \(status)" }
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
