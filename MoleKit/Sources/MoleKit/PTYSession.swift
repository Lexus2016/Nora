import CPTYShim
import Foundation

public enum ExitStatus: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    init(waitStatus status: Int32) {
        // WIFEXITED / WEXITSTATUS / WTERMSIG are macros Swift cannot import.
        let signal = status & 0x7F
        self = signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
    }
}

public enum Key: Sendable {
    case up, down, space, enter, escape, interrupt
    case character(Character)

    var bytes: String {
        switch self {
        case .up: "\u{1B}[A"
        case .down: "\u{1B}[B"
        case .space: " "
        case .enter: "\r"
        case .escape: "\u{1B}"
        case .interrupt: "\u{03}"
        case .character(let character): String(character)
        }
    }
}

public struct PTYError: Error, CustomStringConvertible {
    public let description: String
}

/// A child process on its own pseudo-terminal, mirrored into a `ScreenModel`.
public final class PTYSession: @unchecked Sendable {
    public let pid: pid_t
    private let master: Int32
    private let lock = NSLock()
    private var screen: ScreenModel
    private var transcript: [UInt8] = []
    private var lastOutput = Date()
    private var status: ExitStatus?
    private var closed = false

    /// - Parameter environment: the child's complete environment; nothing is inherited.
    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String? = nil,
        rows: Int = 300,
        cols: Int = 1024
    ) throws {
        screen = ScreenModel(rows: rows, cols: cols)

        // Every C string is built before the fork; the child only calls chdir/execve.
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cwd = currentDirectory.map { strdup($0) } ?? nil
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(cwd)
        }

        var fd: Int32 = -1
        let child = nora_forkpty_exec(executable, argv, envp, cwd, UInt16(rows), UInt16(cols), &fd)
        guard child > 0 else {
            throw PTYError(description: "forkpty failed: \(String(cString: strerror(errno)))")
        }
        pid = child
        master = fd
        ChildProcesses.registerGroup(child)

        DispatchQueue.global().async { [self] in readLoop() }
        DispatchQueue.global().async { [self] in reap() }
    }

    deinit {
        close()
    }

    public var lines: [String] { locked { screen.lines } }
    public var unknownSequences: [String] { locked { screen.unknownSequences } }
    public var exitStatus: ExitStatus? { locked { status } }

    /// Raw output so far, for golden fixtures.
    public var transcriptBytes: [UInt8] { locked { transcript } }

    /// Keys go out as one write each: Mole reads escape sequences with a 1 s timeout per byte.
    public func send(_ key: Key) {
        write(key.bytes)
    }

    public func write(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(master, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Waits until `predicate` holds on a screen that has been quiet for `quiet` seconds.
    @discardableResult
    public func waitUntil(
        timeout: TimeInterval,
        quiet: TimeInterval = 0.25,
        _ what: String,
        _ predicate: ([String]) -> Bool
    ) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (lines, idle, finished) = locked { (screen.lines, Date().timeIntervalSince(lastOutput), status) }
            if idle >= quiet, predicate(lines) { return lines }
            if let finished, idle >= quiet {
                throw PTYError(description: "process exited (\(finished)) while waiting for \(what)\n\(dump(lines))")
            }
            if Date() >= deadline {
                throw PTYError(description: "timed out waiting for \(what)\n\(dump(lines))")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    public func waitForExit(timeout: TimeInterval) throws -> ExitStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = exitStatus { return status }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw PTYError(description: "process \(pid) still running after \(timeout)s\n\(dump(lines))")
    }

    /// SIGTERM, then SIGKILL if the child is still alive after `grace` seconds. The child leads
    /// its own session, so the whole group gets the signal: a pending sudo or askpass included.
    public func terminate(grace: TimeInterval = 2) {
        guard exitStatus == nil || ChildProcesses.groupAlive(pid) else { return }
        kill(-pid, SIGTERM)
        // The leader may be gone while a helper it started lives on in the group: wait for the
        // whole group, not just the leader.
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, exitStatus == nil || ChildProcesses.groupAlive(pid) { usleep(50_000) }
        guard exitStatus == nil || ChildProcesses.groupAlive(pid) else { return }
        kill(-pid, SIGKILL)
        // Returns once the group is really gone, so a caller that puts the whitelist back
        // next never does it under a helper that is still dying.
        let hard = Date().addingTimeInterval(1)
        while Date() < hard, exitStatus == nil || ChildProcesses.groupAlive(pid) { usleep(20_000) }
    }

    public func close() {
        let alreadyClosed = locked {
            defer { closed = true }
            return closed
        }
        guard !alreadyClosed else { return }
        terminate()
        Darwin.close(master)
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var poller = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        while !locked({ closed }) {
            // Poll with a timeout so close() can stop the loop even if a grandchild holds the pts.
            let ready = poll(&poller, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            let count = read(master, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return }

            let replies = locked {
                transcript.append(contentsOf: buffer[0..<count])
                screen.feed(buffer[0..<count])
                lastOutput = Date()
                return screen.takeReplies()
            }
            replies.forEach(write)
        }
    }

    private func reap() {
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
        let exit = ExitStatus(waitStatus: raw)
        locked { status = exit }
        // Out of the registry only when the whole group is gone (see registerGroup).
        while ChildProcesses.groupAlive(pid) { usleep(200_000) }
        ChildProcesses.unregisterGroup(pid)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func dump(_ lines: [String]) -> String {
        lines.filter { !$0.isEmpty }.map { "  | \($0)" }.joined(separator: "\n")
    }
}
