import Foundation
import Testing
@testable import MoleKit

struct InstallerConfirmationRegressionTests {
    private let target = InstallerTarget(name: "Example  Setup.dmg", sources: ["Downloads"], size: "1MB")

    @Test func mismatchDiagnosticsIdentifyPhaseAndEscapeNames() {
        let selection = InstallerDriverError.selectionMismatch(expected: ["Example.dmg"], onScreen: [])
        let review = InstallerDriverError.reviewMismatch(expected: ["Example.dmg"], onScreen: ["Other\nName.dmg"])
        #expect(selection.localizedDescription.contains("selection mismatch: expected 1"))
        #expect(selection.localizedDescription.contains("observed 0"))
        #expect(review.localizedDescription.contains("review mismatch: expected 1"))
        #expect(review.localizedDescription.contains("observed 1"))
        #expect(review.localizedDescription.contains("Other\\nName.dmg"))
        #expect(!review.localizedDescription.contains("\n"))
    }

    @Test func preservesRepeatedSpacesInMenuNames() {
        let rows = InstallerDriver.parseRows([
            "➤ ○ Example  Setup.dmg        1MB | Downloads",
            "  ○ Інсталятор  Test.pkg     2MB | Desktop",
        ])
        #expect(rows.map(\.name) == ["Example  Setup.dmg", "Інсталятор  Test.pkg"])
        #expect(rows.map(\.size) == ["1MB", "2MB"])
        #expect(InstallerDriver.review(["Example  Setup.dmg"], matches: [target]))
        #expect(!InstallerDriver.review(["Example Setup.dmg"], matches: [target]))
    }

    @Test func requiresCompleteExactCountPrompt() {
        for partial in ["➤ Delete 1 installer", "➤ Delete 1 installer, 1MB  Enter confirm, ESC can"] {
            #expect(!InstallerDriver.hasCompleteReviewPrompt([partial], count: 1))
        }
        #expect(InstallerDriver.hasCompleteReviewPrompt([
            "➤ Delete 1 installer, 1MB  Enter confirm, ESC cancel:",
        ], count: 1))
        #expect(InstallerDriver.hasCompleteReviewPrompt([
            "➤ Delete 2 installers, 2MB  Enter confirm, ESC cancel:",
        ], count: 2))
        #expect(!InstallerDriver.hasCompleteReviewPrompt([
            "➤ Delete 11 installers, 11MB  Enter confirm, ESC cancel:",
        ], count: 1))
    }

    @Test func ansiAndUTF8FragmentationPreserveReviewIdentity() {
        let text = "\u{1B}[35mFiles to be removed:\u{1B}[0m\r\n  \u{1B}[32m✓\u{1B}[0m Example  Setup.dmg , 1MB\r\n\r\n➤ Delete 1 installer, 1MB  Enter confirm, ESC cancel:"
        var screen = ScreenModel(rows: 20, cols: 160)
        for byte in text.utf8 { screen.feed([byte]) }
        #expect(screen.unknownSequences.isEmpty)
        #expect(InstallerDriver.parseReview(screen.lines) == [target.name])
        #expect(InstallerDriver.hasCompleteReviewPrompt(screen.lines, count: 1))
    }

    // This fake menu only exchanges keystrokes. It never invokes Mole, reads user files,
    // or deletes anything. Exit 91 means Nora sent a key before the prompt was complete.
    private func session(fragmented: Bool = false, changedReview: Bool = false,
                         changedSize: Bool = false) throws -> PTYSession {
        let size = changedSize ? "2MB" : "1MB"
        let reviewName = changedReview ? "Other.dmg" : "Example  Setup.dmg"
        let script = #"""
        stty -echo
        printf '\033[2J\033[HSelect Installers to Remove , 0B, 0 selected\r\n\r\n➤ ○ Example  Setup.dmg        \#(size) | Downloads\r\n\r\nSpace Select\r\n'
        IFS= read -r -s -n1 -t 5 key || exit 80
        [ "$key" = q ] && exit 0
        [ "$key" = ' ' ] || exit 81
        printf '\033[2J\033[HSelect Installers to Remove , 1MB, 1 selected\r\n\r\n➤ ● Example  Setup.dmg        1MB | Downloads\r\n\r\nSpace Select\r\n'
        IFS= read -r -s -n1 -t 5 key || exit 82
        [ -z "$key" ] || exit 83
        printf '\033[2J\033[HFiles to be removed:\r\n  ✓ \#(reviewName) , 1MB\r\n\r\n➤ Delete 1 installer'
        if [ '\#(fragmented)' = true ]; then
            if IFS= read -r -s -n1 -t 1 key; then exit 91; fi
        fi
        printf ', 1MB  Enter confirm, ESC cancel:'
        IFS= read -r -s -n1 -t 5 key || exit 84
        if [ '\#(changedReview)' = true ]; then
            [ "$key" = $'\033' ] || exit 85
        else
            [ -z "$key" ] || exit 86
        fi
        exit 0
        """#
        return try PTYSession(executable: "/bin/bash", arguments: ["-c", script],
                              environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
                              rows: 20, cols: 160)
    }

    @Test func legitimateRepeatedSpaceNameCompletesHandshake() throws {
        let session = try session()
        defer { session.close() }
        var driver = InstallerDriver()
        driver.timeout = 4
        try driver.delete([target], in: session)
        #expect(try session.waitForExit(timeout: 5) == .exited(0))
    }

    @Test func waitsThroughQuietPartialPrompt() throws {
        let session = try session(fragmented: true)
        defer { session.close() }
        var driver = InstallerDriver()
        driver.timeout = 4
        try driver.delete([target], in: session)
        #expect(try session.waitForExit(timeout: 5) == .exited(0))
    }

    @Test func changedReviewStillCancels() throws {
        let session = try session(changedReview: true)
        defer { session.close() }
        #expect(throws: InstallerDriverError.reviewMismatch(expected: [target.name], onScreen: ["Other.dmg"])) {
            try InstallerDriver().delete([target], in: session)
        }
        #expect(try session.waitForExit(timeout: 5) == .exited(0))
    }

    @Test func changedSizeStillCancelsBeforeSelection() throws {
        let session = try session(changedSize: true)
        defer { session.close() }
        #expect(throws: InstallerDriverError.targetChanged(target.name)) {
            try InstallerDriver().delete([target], in: session)
        }
        #expect(try session.waitForExit(timeout: 5) == .exited(0))
    }
}
