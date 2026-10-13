import Foundation
import Testing
@testable import MoleKit

struct ScreenModelTests {
    private func screen(_ input: String, rows: Int = 6, cols: Int = 40) -> ScreenModel {
        var model = ScreenModel(rows: rows, cols: cols)
        model.feed(Array(input.utf8))
        return model
    }

    @Test func clearHomeAndNewlines() {
        let model = screen("junk\u{1B}[2J\u{1B}[HHello\r\nWorld")
        #expect(model.lines.prefix(2) == ["Hello", "World"])
    }

    @Test func cursorPositionAndEraseToEndOfLine() {
        let model = screen("abcdef\u{1B}[1;3H\u{1B}[K")
        #expect(model.lines[0] == "ab")
    }

    @Test func redrawOverwritesWithClearLine() {
        // Mole's menus repaint from home, clearing each line first.
        let model = screen("\u{1B}[H\u{1B}[2Kfirst long line\r\n\u{1B}[H\u{1B}[2Kshort\r\n")
        #expect(model.lines[0] == "short")
    }

    @Test func decodesMoleIcons() {
        let model = screen("\u{1B}[36m➤ ● Setup.dmg\u{1B}[0m\r\n  ○ Other.pkg")
        #expect(model.lines.prefix(2) == ["➤ ● Setup.dmg", "  ○ Other.pkg"])
    }

    @Test func scrollsAtBottom() {
        let model = screen("a\r\nb\r\nc", rows: 2)
        #expect(model.lines == ["b", "c"])
    }

    @Test func wrapIsDeferredUntilNextCharacter() {
        #expect(screen("abc", rows: 2, cols: 3).lines == ["abc", ""])
        #expect(screen("abcd", rows: 2, cols: 3).lines == ["abc", "d"])
    }

    @Test func ignoresModesAndTitles() {
        let model = screen("\u{1B}[?25l\u{1B}[?2004h\u{1B}]0;title\u{07}\u{1B}(Bok\u{1B}[?25h")
        #expect(model.lines[0] == "ok")
        #expect(model.unknownSequences.isEmpty)
    }

    @Test func recordsUnknownSequences() {
        #expect(screen("\u{1B}[2;5r").unknownSequences == ["CSI 2;5r"])
    }

    @Test func answersCursorPositionQuery() {
        var model = screen("ab\u{1B}[6n")
        #expect(model.takeReplies() == ["\u{1B}[1;3R"])
        #expect(model.takeReplies().isEmpty)
    }

    /// Every recorded Mole transcript must replay without terminal drift.
    @Test func recordedTranscriptsReplayCleanly() throws {
        for url in Fixtures.all(named: "installer-delete-2-of-5.transcript") {
            var model = ScreenModel(rows: 80, cols: 220)
            model.feed(Array(try Data(contentsOf: url)))
            #expect(model.unknownSequences.isEmpty, "\(url.path)")
        }
    }
}

struct PTYSessionTests {
    @Test func ptyIsTheControllingTerminal() throws {
        let session = try PTYSession(
            executable: "/bin/sh",
            arguments: ["-c", "tty; exec 3</dev/tty && echo ctty-ok"],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            rows: 10, cols: 80
        )
        defer { session.close() }
        #expect(try session.waitForExit(timeout: 10) == .exited(0))
        let lines = try session.waitUntil(timeout: 2, "output") { $0.contains("ctty-ok") }
        #expect(lines.contains { $0.hasPrefix("/dev/ttys") })
    }

    /// Test threads block signals; a child that inherited the mask could not stop its own
    /// background jobs (Mole's spinner hung `mo uninstall` exactly like this).
    @Test func childStartsWithDefaultSignals() throws {
        let session = try PTYSession(
            executable: "/bin/bash",
            arguments: ["-c", "sleep 30 & p=$!; kill $p; wait $p; echo \"rc=$?\""],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            rows: 10, cols: 80
        )
        defer { session.close() }
        try session.waitUntil(timeout: 5, "background job killed") { $0.contains("rc=143") }
    }

    @Test func keysReachTheChild() throws {
        let session = try PTYSession(
            executable: "/bin/bash",
            arguments: ["-c", "IFS= read -r -s -n1 k; IFS= read -r -s -n1 -t 1 k2; IFS= read -r -s -n1 -t 1 k3; echo \"got:$k2$k3\""],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            rows: 10, cols: 80
        )
        defer { session.close() }
        Thread.sleep(forTimeInterval: 0.3)
        session.send(.down)
        try session.waitUntil(timeout: 5, "echo") { $0.contains("got:[B") }
        #expect(try session.waitForExit(timeout: 5) == .exited(0))
    }
}
