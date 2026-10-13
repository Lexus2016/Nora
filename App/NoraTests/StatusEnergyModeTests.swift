import XCTest
@testable import Nora

final class StatusEnergyModeTests: XCTestCase {
    // MARK: pmset -g parser (synthetic output, same layout as the real command)

    private func pmset(_ extra: String) -> String {
        """
        System-wide power settings:
        Currently in use:
         standby              1
         displaysleep         10
        \(extra)
         tcpkeepalive         1
        """
    }

    func testLowPowerKeyOneIsLowPowerAndOffersTwoModes() {
        let state = EnergyModeParser.parse(pmset(" lowpowermode         1"))
        XCTAssertEqual(state?.key, .lowPowerMode)
        XCTAssertEqual(state?.current, .low)
        XCTAssertEqual(state?.offered, [.low, .automatic], "High Power needs a powermode key")
    }

    func testLowPowerKeyZeroIsAutomatic() {
        XCTAssertEqual(EnergyModeParser.parse(pmset(" lowpowermode         0"))?.current, .automatic)
    }

    func testPowerModeKeyHasThreeModesAndHighPower() {
        let state = EnergyModeParser.parse(pmset(" powermode           2"))
        XCTAssertEqual(state?.key, .powerMode)
        XCTAssertEqual(state?.current, .high)
        XCTAssertEqual(state?.offered, [.low, .automatic, .high])
    }

    func testUnknownValueIsKnownKeyWithoutCurrentMode() {
        let state = EnergyModeParser.parse(pmset(" powermode           7"))
        XCTAssertEqual(state?.key, .powerMode)
        XCTAssertNil(state?.current)
    }

    func testNoEnergyKeyMeansNoEnergyMode() {
        XCTAssertNil(EnergyModeParser.parse(pmset("")))
    }

    func testFirstOccurrenceWinsWhenSectionsRepeatAKey() {
        let text = """
         lowpowermode         1
         lowpowermode         0
        """
        XCTAssertEqual(EnergyModeParser.parse(text)?.current, .low)
    }

    // MARK: command builder

    func testPowerModeArgumentsMatchTheSetting() {
        XCTAssertEqual(EnergyModeCommand.pmsetArguments(for: .low, key: .powerMode), ["-a", "powermode", "0"])
        XCTAssertEqual(EnergyModeCommand.pmsetArguments(for: .automatic, key: .powerMode), ["-a", "powermode", "1"])
        XCTAssertEqual(EnergyModeCommand.pmsetArguments(for: .high, key: .powerMode), ["-a", "powermode", "2"])
    }

    func testLowPowerKeyHasNoHighPower() {
        XCTAssertNil(EnergyModeCommand.pmsetArguments(for: .high, key: .lowPowerMode))
        XCTAssertNil(EnergyModeCommand.invocation(for: .high, key: .lowPowerMode))
        XCTAssertNil(EnergyModeCommand.displayed(for: .high, key: .lowPowerMode))
    }

    func testDisplayedCommandIsTheShellFormWithSudo() {
        XCTAssertEqual(EnergyModeCommand.displayed(for: .automatic, key: .lowPowerMode),
                       "sudo /usr/bin/pmset -a lowpowermode 0")
        XCTAssertEqual(EnergyModeCommand.displayed(for: .high, key: .powerMode),
                       "sudo /usr/bin/pmset -a powermode 2")
    }

    func testInvocationRunsPrivilegedPmsetThroughSudoAskpass() {
        let invocation = EnergyModeCommand.invocation(for: .low, key: .lowPowerMode)
        XCTAssertEqual(invocation?.executable, "/usr/bin/sudo")
        XCTAssertEqual(invocation?.arguments, ["-A", "/usr/bin/pmset", "-a", "lowpowermode", "1"])
    }

    func testOfferedModesAreAlwaysBuildable() {
        for key in [EnergyModeState.Key.powerMode, .lowPowerMode] {
            let state = EnergyModeState(key: key, current: nil)
            for mode in state.offered {
                XCTAssertNotNil(EnergyModeCommand.invocation(for: mode, key: key), "\(mode) on \(key)")
            }
        }
    }
}
