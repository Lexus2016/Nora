import Foundation
import MoleKit
import XCTest
@testable import Nora

/// The record of commands that outlives the app. Every file lives in a temporary folder of its own;
/// nothing here touches the real Application Support.
@MainActor
final class CommandJournalTests: XCTestCase {
    private func temporaryFolder(_ prefix: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func journal(limit: Int = 256 * 1024) -> (journal: CommandJournal, url: URL) {
        let url = temporaryFolder("nora-journal").appendingPathComponent("commands.log")
        return (CommandJournal(url: url, limit: limit), url)
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testWritesTheStartAndTheEndOfACommand() throws {
        let (journal, url) = journal()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        journal.started(id: id, command: "mo clean --dry-run", now: start)
        journal.finished(id: id, command: "mo clean --dry-run", started: start, status: 0, failure: nil,
                         tail: ["Cleaned 1 GB"], now: start.addingTimeInterval(3.25))
        journal.flush()
        let lines = try text(url).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "a succeeded command leaves no output behind")
        XCTAssertNotNil(lines[0].range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\S* start \[[0-9a-f]{8}\]  mo clean --dry-run$"#,
                                       options: .regularExpression), lines[0])
        XCTAssertTrue(lines[1].contains("end \(CommandJournal.tag(id))  exit 0 (3.2 s)  mo clean --dry-run")
                      || lines[1].contains("end \(CommandJournal.tag(id))  exit 0 (3.3 s)  mo clean --dry-run"), lines[1])
    }

    func testACommandThatFailedKeepsOnlyTheLastLinesItPrinted() throws {
        let (journal, url) = journal()
        let id = UUID()
        let output = (0..<30).map { "line \($0)" }
        journal.finished(id: id, command: "mo purge --yes", started: Date(), status: 3, failure: nil, tail: output)
        journal.flush()
        let body = try text(url)
        XCTAssertTrue(body.contains("exit 3"))
        XCTAssertEqual(body.components(separatedBy: "    | ").count - 1, CommandJournal.tailLines)
        XCTAssertTrue(body.contains("    | line 29"))
        XCTAssertFalse(body.contains("    | line 9\n"), "older lines are dropped")
    }

    func testAStoppedCommandSaysWhyAndAnEmptyTailLineIsSkipped() throws {
        let (journal, url) = journal()
        journal.finished(id: UUID(), command: "brew upgrade", started: Date(), status: nil, failure: "Stopped",
                         tail: ["", "  ", "partial output"])
        journal.flush()
        let body = try text(url)
        XCTAssertTrue(body.contains("failed: Stopped"))
        XCTAssertEqual(body.components(separatedBy: "    | ").count - 1, 1)
        XCTAssertTrue(body.contains("    | partial output"))
    }

    func testVeryLongLinesAreClipped() throws {
        let (journal, url) = journal()
        journal.finished(id: UUID(), command: "mo clean", started: Date(), status: 1, failure: nil,
                         tail: [String(repeating: "x", count: 5_000)])
        journal.flush()
        XCTAssertLessThan(try text(url).count, 800)
    }

    func testTheFileIsReadableByTheUserOnly() throws {
        let (journal, url) = journal()
        journal.session("Nora 1.3.4 (10) started")
        journal.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(try text(url).contains("note  Nora 1.3.4 (10) started"))
    }

    func testTheNewerFileReplacesTheOlderWhenItFills() throws {
        let (journal, url) = journal(limit: 300)
        for index in 0..<12 { journal.session("entry number \(index) with some padding to fill the file") }
        journal.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.olderURL.path), "the full file was set aside")
        XCTAssertEqual(journal.olderURL.lastPathComponent, "commands.1.log")
        XCTAssertLessThanOrEqual(try text(url).utf8.count, 300 + 120, "the current file stays near the limit")
        let kept = try text(journal.olderURL) + (try text(url))
        XCTAssertTrue(kept.contains("entry number 11"), "the newest entry is never lost")
        XCTAssertFalse(kept.contains("entry number 0 "), "the oldest entries fall off after two rotations")
    }

    func testAJournalThatCannotBeWrittenNeverThrows() {
        let blocked = CommandJournal(url: URL(fileURLWithPath: "/dev/null/never/commands.log"))
        blocked.session("this must not crash or throw")
        blocked.flush()
    }

    // MARK: - Through the console

    func testTheConsoleWritesEveryCommandOnceWhenItStopsRunning() throws {
        let (journal, url) = journal()
        let console = ConsoleLog()
        console.journal = journal
        let id = console.begin(ShellCommand("/opt/homebrew/bin/mo", ["uninstall", "Some App"]))
        console.append(id, ["Removing…", "could not remove cache"])
        console.finish(id, status: 1)
        console.finish(id, status: 1)
        journal.flush()
        let body = try text(url)
        XCTAssertEqual(body.components(separatedBy: " start ").count - 1, 1)
        XCTAssertEqual(body.components(separatedBy: " end ").count - 1, 1, "a second finish is not a second end")
        XCTAssertTrue(body.contains("mo uninstall 'Some App'"), "the exact command line, as the console shows it")
        XCTAssertTrue(body.contains("    | could not remove cache"))
    }

    func testAFailureThatNeverStartedIsRecorded() throws {
        let (journal, url) = journal()
        let console = ConsoleLog()
        console.journal = journal
        let id = console.begin(ShellCommand("mo", ["clean"]))
        console.fail(id, error: NoraError.moleMissing)
        journal.flush()
        XCTAssertTrue(try text(url).contains("failed: "))
    }

    func testWithoutAJournalTheConsoleBehavesAsBefore() {
        let console = ConsoleLog()
        let id = console.begin(ShellCommand("mo", ["status"]))
        XCTAssertTrue(console.entries[0].isRunning)
        console.finish(id, status: 0)
        XCTAssertFalse(console.entries[0].isRunning)
    }

    // MARK: - What quitting would cut off

    func testRunningWorkFollowsTheCommandsStillOpenInTheConsole() {
        let app = AppModel(visualSnapshot: true, home: temporaryFolder("nora-quit"))
        XCTAssertFalse(app.hasRunningWork)
        XCTAssertEqual(app.runningCommands, [])
        let id = app.console.begin(ShellCommand("mo", ["clean", "--dry-run"]))
        XCTAssertTrue(app.hasRunningWork, "quitting now would stop it half way")
        XCTAssertEqual(app.runningCommands, ["mo clean --dry-run"])
        app.console.finish(id, status: 0)
        XCTAssertFalse(app.hasRunningWork)
    }
}
