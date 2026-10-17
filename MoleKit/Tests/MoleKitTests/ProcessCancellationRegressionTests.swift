import Foundation
import Darwin
import Testing
@testable import MoleKit

struct ProcessCancellationRegressionTests {
    @Test func cancelledRunJoinsChildBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nora-cancel-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("late-write")
        let ready = directory.appendingPathComponent("ready-pid")
        // A synthetic producer that ignores TERM and would write after its slow child exits.
        // Nothing outside this fresh temporary directory can be changed.
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                ["-c", "trap '' TERM; printf '%s' $$ > \"$2\"; /bin/sleep 10; printf late > \"$1\"", "fixture", marker.path, ready.path],
                environment: ["PATH": "/usr/bin:/bin"])
        }
        let deadline = Date().addingTimeInterval(5)
        var pid: pid_t?
        while Date() < deadline {
            if let text = try? String(contentsOf: ready, encoding: .utf8), let value = Int32(text) {
                pid = value
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let pid else {
            task.cancel()
            _ = try? await task.value
            Issue.record("Synthetic producer did not become ready")
            return
        }
        task.cancel()
        let result = try await task.value
        #expect(!result.succeeded)
        #expect(kill(pid, 0) != 0)
        #expect(!ChildProcesses.groupAlive(pid))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func callbackRunKeepsFullSeparatedOutput() async throws {
        let emitted = DataBuffer()
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "printf 'one\\ntwo'; printf 'warning\\n' >&2"], environment: ["PATH": "/usr/bin:/bin"],
            onOutput: { emitted.append(Data(($0.text + "\n").utf8)) })
        #expect(result.stdout == "one\ntwo")
        #expect(result.stderr == "warning\n")
        #expect(emitted.string.contains("one\n"))
        #expect(emitted.string.contains("two\n"))
        #expect(emitted.string.contains("warning\n"))
    }
}
