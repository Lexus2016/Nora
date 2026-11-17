import AppKit
import XCTest
@testable import Nora

/// When quitting asks first. Asking while the system shuts down would hold up the whole Mac,
/// so those quits must go through.
final class QuitGuardTests: XCTestCase {
    func testTheReasonCodesAreTheFourCharacterCodesTheSystemSends() {
        XCTAssertEqual(QuitGuard.reasonKey, 0x7768_793F, "'why?'")
        XCTAssertEqual(QuitGuard.systemReasons, [0x7368_7574, 0x7265_7374, 0x726C_676F, 0x6C6F_676F],
                       "'shut', 'rest', 'rlgo', 'logo'")
    }

    func testShutdownRestartAndLogoutAreSystemInitiated() {
        for code: FourCharCode in [0x7368_7574, 0x7265_7374, 0x726C_676F, 0x6C6F_676F] {
            XCTAssertTrue(QuitGuard.isSystemInitiated([code]))
        }
        XCTAssertTrue(QuitGuard.isSystemInitiated([0, 0x7368_7574]), "either way the code can arrive")
    }

    func testAnOrdinaryQuitCarriesNoSystemReason() {
        XCTAssertFalse(QuitGuard.isSystemInitiated([]))
        XCTAssertFalse(QuitGuard.isSystemInitiated([0]))
        XCTAssertFalse(QuitGuard.isSystemInitiated([0x7175_6961]), "'quia' is not a system shutdown")
    }

    func testItAsksOnlyWhenWorkIsRunningAndTheUserIsTheOneQuitting() {
        XCTAssertTrue(QuitGuard.shouldAsk(hasRunningWork: true, unattended: false, reasons: []))
        XCTAssertFalse(QuitGuard.shouldAsk(hasRunningWork: false, unattended: false, reasons: []),
                       "nothing to lose, nothing to ask")
        XCTAssertFalse(QuitGuard.shouldAsk(hasRunningWork: true, unattended: true, reasons: []),
                       "a SIGTERM sent on purpose is obeyed")
        XCTAssertFalse(QuitGuard.shouldAsk(hasRunningWork: true, unattended: false, reasons: [0x726C_676F]),
                       "logging out is never held up")
    }

    // MARK: - The reason on the quit event

    private enum Slot { case parameter, attribute }

    private func quitEvent(reason: NSAppleEventDescriptor?, as slot: Slot = .parameter) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        guard let reason else { return event }
        switch slot {
        case .parameter: event.setParam(reason, forKeyword: QuitGuard.reasonKey)
        case .attribute: event.setAttribute(reason, forKeyword: QuitGuard.reasonKey)
        }
        return event
    }

    func testTheReasonIsReadWhicheverWayTheSystemEncodesItAndWhereverItPutsIt() {
        XCTAssertEqual(QuitGuard.reasonKey, FourCharCode(kAEQuitReason), "the key the SDK defines")
        for code in [kAELogOut, kAEReallyLogOut, kAEShutDown, kAERestart] {
            let encodings: [(String, NSAppleEventDescriptor)] = [
                ("enumeration", NSAppleEventDescriptor(enumCode: FourCharCode(code))),
                ("type", NSAppleEventDescriptor(typeCode: FourCharCode(code))),
                ("integer", NSAppleEventDescriptor(int32: Int32(bitPattern: FourCharCode(code)))),
            ]
            for (name, descriptor) in encodings {
                for slot in [Slot.parameter, .attribute] {
                    let reasons = QuitGuard.reasons(in: quitEvent(reason: descriptor, as: slot))
                    XCTAssertTrue(QuitGuard.isSystemInitiated(reasons), "\(code) sent as \(name) in the \(slot) must be recognised: \(reasons)")
                }
            }
        }
    }

    func testTheSystemQuitCodesAreTheSDKsAndAQuitAllIsNotASystemQuit() {
        XCTAssertEqual(QuitGuard.systemReasons, [FourCharCode(kAEShutDown), FourCharCode(kAERestart),
                                                 FourCharCode(kAEReallyLogOut), FourCharCode(kAELogOut)])
        let quitAll = QuitGuard.reasons(in: quitEvent(reason: NSAppleEventDescriptor(enumCode: FourCharCode(kAEQuitAll))))
        XCTAssertFalse(QuitGuard.isSystemInitiated(quitAll), "an ordinary quit-all still asks")
    }

    func testAQuitWithoutAReasonOrWithAnUnknownOneIsNotTheSystems() {
        XCTAssertEqual(QuitGuard.reasons(in: quitEvent(reason: nil)), [], "⌘Q, the app menu and the Dock send none")
        XCTAssertEqual(QuitGuard.reasons(in: nil), [], "no event is being handled")
        let unknown = QuitGuard.reasons(in: quitEvent(reason: NSAppleEventDescriptor(enumCode: 0x7175_6961)))
        XCTAssertFalse(QuitGuard.isSystemInitiated(unknown))
        XCTAssertTrue(QuitGuard.shouldAsk(hasRunningWork: true, unattended: false, reasons: unknown))
    }

    // MARK: - The workspace's power-off notice

    func testAPowerOffNoticeSilencesTheQuestionOnlyForAWhile() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(QuitGuard.shouldAsk(hasRunningWork: true, unattended: false, reasons: [],
                                           powerOffNoticedAt: now.addingTimeInterval(-5), now: now),
                       "a logout was announced a moment ago: the quit is the system's")
        XCTAssertTrue(QuitGuard.shouldAsk(hasRunningWork: true, unattended: false, reasons: [],
                                          powerOffNoticedAt: now.addingTimeInterval(-QuitGuard.powerOffWindow - 1), now: now),
                      "a logout the user cancelled must not silence every later quit")
        XCTAssertTrue(QuitGuard.shouldAsk(hasRunningWork: true, unattended: false, reasons: [], powerOffNoticedAt: nil, now: now))
        XCTAssertFalse(QuitGuard.shouldAsk(hasRunningWork: false, unattended: false, reasons: [],
                                           powerOffNoticedAt: nil, now: now), "nothing running, nothing to ask")
    }

    // MARK: - The question itself

    @MainActor
    func testTheQuestionKeepsNoraWorkingByDefaultAndNamesWhatIsRunning() {
        let alert = QuitGuard.makeAlert(commands: ["mo clean --dry-run", "brew upgrade", "clamscan ~/Downloads/a.zip", "mo purge"])
        XCTAssertEqual(alert.buttons.count, 2)
        XCTAssertEqual(alert.buttons[0].title, String(localized: "Keep Working"), "the first button is the default, the one Return presses")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].title, String(localized: "Stop and Quit"))
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertTrue(alert.informativeText.contains("mo clean --dry-run"))
        XCTAssertTrue(alert.informativeText.contains("clamscan ~/Downloads/a.zip"))
        XCTAssertFalse(alert.informativeText.contains("mo purge"), "three commands are listed, the rest are an ellipsis")
        XCTAssertTrue(alert.informativeText.hasSuffix("…"))
    }

    @MainActor
    func testAVeryLongCommandIsClippedInTheQuestion() {
        let alert = QuitGuard.makeAlert(commands: [String(repeating: "x", count: 900)])
        XCTAssertLessThan(alert.informativeText.count, 400)
    }
}
