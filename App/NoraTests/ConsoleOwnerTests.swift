import XCTest
import MoleKit
@testable import Nora

/// Two modules run commands at the same time (Cleanup cleans while Applications updates): each
/// scene must show its own command's output, never the one that started last.
@MainActor
final class ConsoleOwnerTests: XCTestCase {
    func testEachModuleReadsOnlyItsOwnOutput() async {
        let console = ConsoleLog()
        await Task(.cleanup) {
            let id = console.begin(ShellCommand("mo", ["clean"]))
            console.append(id, ["→ ~/Library/Caches/Example"])
        }.value
        await Task(.applications) {
            let id = console.begin(ShellCommand("brew", ["upgrade", "--cask", "example-app"]))
            console.append(id, ["==> Upgrading example-app"])
        }.value

        XCTAssertEqual(console.output(of: .cleanup), ["→ ~/Library/Caches/Example"])
        XCTAssertEqual(console.output(of: .applications), ["==> Upgrading example-app"])
        XCTAssertEqual(console.output(of: .projects), [])
    }

    func testCommandsStartedOutsideAModuleBelongToNone() {
        let console = ConsoleLog()
        _ = console.begin(ShellCommand("mo", ["--version"]))
        XCTAssertNil(console.entries.last?.owner)
        XCTAssertEqual(console.output(of: .cleanup), [])
    }

    func testAStoppedCommandIsMarkedStoppedNotRunning() async {
        let console = ConsoleLog()
        var stopped = false
        let task = Task(.cleanup) {
            let id = console.begin(ShellCommand("mo", ["clean"]))
            withUnsafeCurrentTask { $0?.cancel() }
            do { try console.checkStopped(id) } catch { stopped = error is CancellationError }
        }
        await task.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(console.entries.last?.isRunning, false)
        XCTAssertNotNil(console.entries.last?.failure)
    }
}
