import Foundation

/// Runs a command in a PTY to completion (for commands that need a terminal or the same-tty
/// sudo session) and returns its full output as plain text.
public enum PTYRun {
    public struct Result: Sendable {
        public let status: ExitStatus
        public let text: String
        public var succeeded: Bool { status == .exited(0) }
    }

    /// - Parameters:
    ///   - sudo: authenticate with `sudo -A -v` in the same PTY first; `SUDO_ASKPASS` must be set.
    ///   - onScreen: called about three times a second with the visible screen.
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        sudo: Bool = false,
        timeout: TimeInterval = 3600,
        onScreen: (@Sendable ([String]) -> Void)? = nil
    ) async throws -> Result {
        let (exe, args) = sudo ? PrivilegeBroker.wrap(executable: executable, arguments: arguments) : (executable, arguments)
        let session = try PTYSession(executable: exe, arguments: args, environment: environment)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let deadline = Date().addingTimeInterval(timeout)
                    while session.exitStatus == nil, Date() < deadline {
                        onScreen?(session.lines)
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                    guard let status = session.exitStatus else {
                        session.terminate()
                        continuation.resume(throwing: PTYError(description: "timed out after \(Int(timeout)) s"))
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                    onScreen?(session.lines)
                    continuation.resume(returning: Result(status: status, text: TerminalText.render(session.transcriptBytes)))
                }
            }
        } onCancel: {
            session.terminate()
        }
    }
}

extension PTYRun {
    /// Runs `drive` against a live PTY session (menu and prompt drivers), then waits for the
    /// command to exit. A driver error cancels the session.
    public static func drive<T: Sendable>(
        executable: String,
        arguments: [String],
        environment: [String: String],
        sudo: Bool = false,
        exitTimeout: TimeInterval = 1800,
        onScreen: (@Sendable ([String]) -> Void)? = nil,
        _ drive: @escaping @Sendable (PTYSession) throws -> T
    ) async throws -> (value: T, result: Result) {
        let (exe, args) = sudo ? PrivilegeBroker.wrap(executable: executable, arguments: arguments) : (executable, arguments)
        let session = try PTYSession(executable: exe, arguments: args, environment: environment)
        let mirror = DispatchSource.makeTimerSource(queue: .global())
        mirror.schedule(deadline: .now(), repeating: 0.3)
        mirror.setEventHandler { onScreen?(session.lines) }
        mirror.resume()
        defer { mirror.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(value: T, result: Result), Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let value = try drive(session)
                        let status = try session.waitForExit(timeout: exitTimeout)
                        Thread.sleep(forTimeInterval: 0.1)
                        onScreen?(session.lines)
                        continuation.resume(returning: (value, Result(status: status, text: TerminalText.render(session.transcriptBytes))))
                    } catch {
                        session.terminate()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            session.terminate()
        }
    }
}

/// Turns raw terminal output into plain lines: drops escape sequences and keeps what a
/// carriage return overwrote last (spinners, progress).
public enum TerminalText {
    public static func render(_ bytes: [UInt8]) -> String {
        let raw = String(decoding: bytes, as: UTF8.self)
        let stripped = raw
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][A-Za-z0-9]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        return stripped.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let parts = line.split(separator: "\r", omittingEmptySubsequences: false)
            return String(parts.last(where: { !$0.isEmpty }) ?? "")
        }.joined(separator: "\n")
    }
}

/// The closing block Mole prints between `=====` rulers ("Cleanup complete", "Space freed").
public enum MoleSummary {
    public static func lines(_ output: String) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ANSIText.strip(String($0)).trimmingCharacters(in: .whitespaces) }
        let rulers = lines.indices.filter { lines[$0].hasPrefix("=====") }
        if rulers.count >= 2 {
            let a = rulers[rulers.count - 2], b = rulers[rulers.count - 1]
            return lines[(a + 1)..<b].filter { !$0.isEmpty }
        }
        return Array(lines.filter { !$0.isEmpty }.suffix(4))
    }
}
