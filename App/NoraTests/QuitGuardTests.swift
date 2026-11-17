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
}
