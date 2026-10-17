import CPTYShim
import Darwin
import Foundation

/// Explicitly bridges cancellation into synchronous protection checks and PTY driver callbacks.
/// A cancelled Swift parent does not automatically cancel a detached worker or a Dispatch block.
public final class MoleProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var children = 0

    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public func checkCancellation() throws {
        if lock.withLock({ cancelled }) || ChildProcesses.isShuttingDown { throw CancellationError() }
    }
    /// An unresolved child keeps the overlay in place until its owner proves settlement.
    public var canRestoreProtection: Bool { lock.withLock { children == 0 } }
    fileprivate func retainChild() { lock.withLock { children += 1 } }
    fileprivate func releaseChild() { lock.withLock { children -= 1 } }
}

public enum MoleProbeError: Error, CustomStringConvertible, LocalizedError {
    case timedOut
    case invalidResponse(String)
    case io(String)
    case unsettled

    public var description: String {
        switch self {
        case .timedOut: "The command probe timed out."
        case .invalidResponse(let detail): "The command probe returned an invalid response: \(detail)"
        case .io(let detail): "The command probe failed: \(detail)"
        case .unsettled: "The command helper has not stopped. Recovery must wait until it stops."
        }
    }
    public var errorDescription: String? { description }
}

/// Production settlement policy; tests can inject an inconclusive membership observation.
struct ProbeSettlement: Sendable {
    var grace: TimeInterval = 2
    var hardGrace: TimeInterval = 1
    var otherMembers: @Sendable (pid_t) -> Int32 = { nora_probe_group_others($0) }
}

/// A synchronous, bounded exchange, with one owner for all three nonblocking descriptors.
/// There is no background writer to outlive a return, and reads cannot block cancellation.
enum ManagedProbe {
    static let maximumBytes = 16 * 1024 * 1024

    static func run(_ executable: String, _ arguments: [String], environment: [String: String],
                    timeout: TimeInterval = 120, cancellation: MoleProbeCancellation = MoleProbeCancellation(),
                    initialInput: Data? = Data(), settlement: ProbeSettlement = ProbeSettlement(),
                    inputAfterOutput: ((Data) throws -> Data?)? = nil) throws -> CommandResult {
        guard timeout.isFinite, timeout > 0 else { throw MoleProbeError.io("invalid timeout") }
        try cancellation.checkCancellation()
        let child = try ChildProcesses.launchProbe {
            try ManagedProbeChild(executable, arguments, environment: environment, cancellation: cancellation,
                                  settlement: settlement)
        }
        defer { child.closeDescriptors() }
        var result: (stdout: Data, stderr: Data)?
        var failure: Error?
        do {
            result = try exchange(child, timeout: timeout, cancellation: cancellation,
                                  initialInput: initialInput, inputAfterOutput: inputAfterOutput)
        } catch { failure = error }
        // This is a barrier, not fire-and-forget termination. An inconclusive barrier retains
        // both the owned leader and the recovery hold, and reports failure to the caller.
        guard child.settle() else { throw MoleProbeError.unsettled }
        if let failure { throw failure }
        try cancellation.checkCancellation()
        guard let result, let text = String(data: result.stdout, encoding: .utf8) else {
            throw MoleProbeError.invalidResponse("non-UTF-8 output")
        }
        let diagnostics = String(data: result.stderr, encoding: .utf8)
            ?? "[Non-UTF-8 diagnostic bytes were replaced.]\n" + String(decoding: result.stderr, as: UTF8.self)
        return CommandResult(status: child.exitCode, stdout: text, stderr: diagnostics)
    }

    private static func exchange(_ child: ManagedProbeChild, timeout: TimeInterval,
                                 cancellation: MoleProbeCancellation, initialInput: Data?,
                                 inputAfterOutput: ((Data) throws -> Data?)?) throws -> (stdout: Data, stderr: Data) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var outgoing = initialInput
        var offset = 0
        var answer = Data(), diagnostics = Data()
        var eof = false, errorEOF = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try cancellation.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MoleProbeError.timedOut }
            if let outgoing, outgoing.count > maximumBytes { throw MoleProbeError.io("input exceeded the safety limit") }
            if let outgoing, offset == outgoing.count { child.closeInput() }
            let exited = try child.hasExited()
            if eof && errorEOF && exited {
                guard let outgoing, offset == outgoing.count else {
                    throw MoleProbeError.io("helper exited before receiving all paths")
                }
                return (answer, diagnostics)
            }
            var descriptors = [
                pollfd(fd: eof ? -1 : child.output, events: Int16(POLLIN), revents: 0),
                pollfd(fd: outgoing == nil ? -1 : child.input, events: Int16(POLLOUT), revents: 0),
                pollfd(fd: errorEOF ? -1 : child.diagnostic, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 25)
            if ready < 0 {
                if errno == EINTR { continue }
                throw MoleProbeError.io("poll: \(String(cString: strerror(errno)))")
            }
            if descriptors.contains(where: { $0.revents & Int16(POLLNVAL) != 0 }) {
                throw MoleProbeError.io("a probe descriptor became invalid")
            }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                // Read one bounded chunk per turn, so a flooding helper cannot starve timeout
                // or cancellation checks, nor the input side of this two-way exchange.
                let count = Darwin.read(child.output, &buffer, buffer.count)
                if count > 0 {
                    guard answer.count + diagnostics.count <= maximumBytes - count else { throw MoleProbeError.io("output exceeded the safety limit") }
                    answer.append(contentsOf: buffer.prefix(count))
                    if outgoing == nil { outgoing = try inputAfterOutput?(answer) }
                } else if count == 0 { eof = true }
                else if errno != EINTR && errno != EAGAIN {
                    throw MoleProbeError.io("read: \(String(cString: strerror(errno)))")
                }
            }
            if descriptors[2].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                // stderr has its own bounded buffer and never participates in protection
                // framing. A noisy diagnostic stream must not block stdout or stdin.
                let count = Darwin.read(child.diagnostic, &buffer, buffer.count)
                if count > 0 {
                    guard answer.count + diagnostics.count <= maximumBytes - count else { throw MoleProbeError.io("output exceeded the safety limit") }
                    diagnostics.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { errorEOF = true }
                else if errno != EINTR && errno != EAGAIN {
                    throw MoleProbeError.io("stderr read: \(String(cString: strerror(errno)))")
                }
            }
            if let outgoing, child.input >= 0,
               descriptors[1].revents & Int16(POLLOUT | POLLHUP | POLLERR) != 0 {
                let count = outgoing.withUnsafeBytes { bytes in
                    nora_probe_write(child.input, bytes.baseAddress!.advanced(by: offset), min(16_384, bytes.count - offset))
                }
                if count > 0 { offset += count }
                else if count == 0 { throw MoleProbeError.io("zero-byte input write") }
                else if errno != EINTR && errno != EAGAIN {
                    throw MoleProbeError.io("write: \(String(cString: strerror(errno)))")
                }
            }
        }
    }
}

/// Holds the unreaped leader as an ownership pin. All signaling and reaping use the same lock;
/// even a quit sweep that captured this object earlier cannot signal a recycled process ID.
final class ManagedProbeChild: @unchecked Sendable {
    let pid: pid_t
    private(set) var input: Int32
    let output: Int32
    let diagnostic: Int32
    private let lock = NSLock()
    private let cancellation: MoleProbeCancellation
    private let settlement: ProbeSettlement
    private var reaped = false
    private var ownershipLost = false
    private var status: Int32 = -1

    fileprivate init(_ executable: String, _ arguments: [String], environment: [String: String],
         cancellation: MoleProbeCancellation, settlement: ProbeSettlement) throws {
        guard ([executable] + arguments + Array(environment.keys) + Array(environment.values)).allSatisfy({ !$0.utf8.contains(0) }) else {
            throw MoleProbeError.io("a command argument contained NUL")
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var inputFD: Int32 = -1, outputFD: Int32 = -1, errorFD: Int32 = -1
        let child = nora_probe_spawn(executable, argv, envp, &inputFD, &outputFD, &errorFD)
        guard child > 0 else { throw MoleProbeError.io("spawn: \(String(cString: strerror(errno)))") }
        pid = child; input = inputFD; output = outputFD; diagnostic = errorFD
        self.cancellation = cancellation
        self.settlement = settlement
        cancellation.retainChild()
    }

    var exitCode: Int32 { lock.withLock { status } }
    var isSettled: Bool { lock.withLock { reaped } }

    func signal(_ value: Int32) {
        lock.withLock {
            // A zombie leader still reserves this ID. Never send a signal after waitpid.
            guard !reaped, !ownershipLost else { return }
            var observed: Int32 = 0
            if nora_probe_exited(pid, &observed) < 0, errno == ECHILD {
                ownershipLost = true
                return
            }
            kill(-pid, value)
        }
    }

    func hasExited() throws -> Bool {
        try lock.withLock {
            if reaped { return true }
            let result = nora_probe_exited(pid, &status)
            if result < 0 {
                if errno == EINTR { return false }
                if errno == ECHILD { ownershipLost = true }
                throw MoleProbeError.io("waitid: \(String(cString: strerror(errno)))")
            }
            return result == 1
        }
    }

    func closeInput() { if input >= 0 { Darwin.close(input); input = -1 } }
    func closeDescriptors() { closeInput(); Darwin.close(output); Darwin.close(diagnostic) }

    /// The process list excludes the reserved leader; waiting for group ESRCH before reaping
    /// the leader would deadlock on a zombie. A failed/full process-list query is inconclusive.
    private func reapIfSettled() -> Bool {
        let (finished, newlyReaped) = lock.withLock { () -> (Bool, Bool) in
            if reaped { return (true, false) }
            guard !ownershipLost else { return (false, false) }
            let observation = nora_probe_exited(pid, &status)
            if observation < 0, errno == ECHILD { ownershipLost = true }
            guard observation == 1, settlement.otherMembers(pid) == 0 else { return (false, false) }
            var raw: Int32 = 0
            let waited = waitpid(pid, &raw, WNOHANG)
            if waited < 0, errno == ECHILD { ownershipLost = true }
            guard waited == pid else { return (false, false) }
            reaped = true
            return (true, true)
        }
        if newlyReaped {
            ChildProcesses.unregisterProbe(self)
            // Only this runner or its post-timeout observer calls this method. Stop sweeps
            // inspect isSettled and signal; they never reap or release the recovery hold.
            cancellation.releaseChild()
        }
        return finished
    }

    func settle() -> Bool {
        closeInput()
        if reapIfSettled() { return true }
        signal(SIGTERM)
        if awaitSettlement(until: ProcessInfo.processInfo.systemUptime + settlement.grace) { return true }
        signal(SIGKILL)
        if awaitSettlement(until: ProcessInfo.processInfo.systemUptime + settlement.hardGrace) { return true }
        // Preserve the ownership pin and recovery hold. The observer never restores state;
        // it only releases them after every owned group member is proven gone.
        DispatchQueue.global(qos: .utility).async { [self] in
            while !reapIfSettled(), !lock.withLock({ ownershipLost }) { usleep(100_000) }
        }
        return false
    }

    private func awaitSettlement(until deadline: TimeInterval) -> Bool {
        repeat {
            if reapIfSettled() { return true }
            if lock.withLock({ ownershipLost }) { return false }
            usleep(20_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
}


extension ProcessRunner {
    /// A bounded read-only probe. Parent cancellation is bridged into the synchronous owner;
    /// return (or throw) follows settlement of the child and its owned group. stdout and stderr
    /// are separate, with a combined 16 MiB bound; malformed diagnostic UTF-8 is visibly replaced.
    public static func probe(_ executable: URL, _ arguments: [String], environment: [String: String],
                             timeout: TimeInterval = 15) async throws -> CommandResult {
        let cancellation = MoleProbeCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached {
                try ManagedProbe.run(executable.path, arguments, environment: environment,
                                     timeout: timeout, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }
}
