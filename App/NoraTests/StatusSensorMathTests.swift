import XCTest
@testable import Nora

final class StatusSensorMathTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testEnergyUnitsConvertToJoules() {
        XCTAssertEqual(SensorMath.joules(1_000_000_000, unit: "nJ") ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(SensorMath.joules(1_000_000, unit: "uJ") ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(SensorMath.joules(1_000, unit: "mJ") ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(SensorMath.joules(2, unit: "J") ?? -1, 2, accuracy: 1e-12)
    }

    func testUnknownUnitAndNegativeValueAreRejected() {
        XCTAssertNil(SensorMath.joules(5, unit: "kWh"))
        XCTAssertNil(SensorMath.joules(-5, unit: "mJ"))
    }

    func testWattsNeedAUsableWindowAndPlausibleResult() {
        XCTAssertEqual(SensorMath.watts(joules: 2, seconds: 2) ?? -1, 1, accuracy: 1e-12)
        XCTAssertNil(SensorMath.watts(joules: 0.05, seconds: 0.1), "a 0.1 s window is too short")
        XCTAssertNil(SensorMath.watts(joules: 10_000, seconds: 1), "above 500 W is treated as a bad sample")
    }

    func testPowerChannelsMapToComponents() {
        XCTAssertEqual(SensorMath.powerComponent(for: "CPU Energy"), .cpu)
        XCTAssertEqual(SensorMath.powerComponent(for: "GPU Energy"), .gpu)
        XCTAssertEqual(SensorMath.powerComponent(for: "ANE0"), .ane)
        // Per-core and per-cluster channels are not summed: that would double count the total.
        XCTAssertNil(SensorMath.powerComponent(for: "PCPU1DTL00"))
        XCTAssertNil(SensorMath.powerComponent(for: "GPU0"))
    }

    // MARK: energy totals

    func testTotalsSumChannelsPerComponentInJoules() {
        let totals = PowerSampler.energyTotals([
            EnergyChannel(name: "CPU Energy", unit: "mJ", value: 2_000),
            EnergyChannel(name: "GPU Energy", unit: "nJ", value: 500_000_000),
            EnergyChannel(name: "ANE0", unit: "mJ", value: 300),
            EnergyChannel(name: "ANE1", unit: "mJ", value: 200),
        ])
        XCTAssertEqual(totals[.cpu] ?? -1, 2, accuracy: 1e-12)
        XCTAssertEqual(totals[.gpu] ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(totals[.ane] ?? -1, 0.5, accuracy: 1e-12)
    }

    func testComponentWithAnUnknownUnitIsLeftOutNotGuessed() {
        let totals = PowerSampler.energyTotals([
            EnergyChannel(name: "GPU Energy", unit: "bogus", value: 1_000),
            EnergyChannel(name: "CPU Energy", unit: "mJ", value: 1_000),
        ])
        XCTAssertNil(totals[.gpu])
        XCTAssertEqual(totals[.cpu] ?? -1, 1, accuracy: 1e-12)
    }

    // MARK: step counter

    func testFirstStepGivesNoWatts() {
        var counter = StepCounterPower()
        counter.observe(joules: 100, uptime: 0)
        counter.observe(joules: 150, uptime: 10 * second)  // first step: no start time for its window
        XCTAssertNil(counter.current(at: 10 * second, maxAge: 600 * second))
    }

    func testWattsAppearAtTheSecondStepAndUseTheWindowBetweenSteps() {
        var counter = StepCounterPower()
        counter.observe(joules: 100, uptime: 0)
        counter.observe(joules: 150, uptime: 10 * second)     // first step
        counter.observe(joules: 350, uptime: 30 * second)     // second step: +200 J over 20 s
        XCTAssertEqual(counter.current(at: 30 * second, maxAge: 600 * second) ?? -1, 10, accuracy: 1e-9)
    }

    func testPollsWithoutAStepKeepTheLastWattsUntilTheMaxAge() {
        var counter = StepCounterPower()
        counter.observe(joules: 0, uptime: 0)
        counter.observe(joules: 10, uptime: 1 * second)
        counter.observe(joules: 20, uptime: 2 * second)       // 10 W
        counter.observe(joules: 20, uptime: 5 * second)       // no step
        XCTAssertEqual(counter.current(at: 5 * second, maxAge: 600 * second) ?? -1, 10, accuracy: 1e-9)
        XCTAssertNil(counter.current(at: 700 * second, maxAge: 600 * second), "older than the max age is unavailable")
    }

    /// A big jump after a long quiet period must not be divided by the short poll interval.
    func testLargeStepAfterALongGapIsAveragedOverTheGap() {
        var counter = StepCounterPower()
        counter.observe(joules: 0, uptime: 0)
        counter.observe(joules: 100, uptime: 60 * second)     // first step, no watts yet
        counter.observe(joules: 100 + 600, uptime: 120 * second)  // 600 J over 60 s = 10 W, not 600 J over 2 s
        XCTAssertEqual(counter.current(at: 120 * second, maxAge: 600 * second) ?? -1, 10, accuracy: 1e-9)
    }

    func testCounterResetStartsOver() {
        var counter = StepCounterPower()
        counter.observe(joules: 100, uptime: 0)
        counter.observe(joules: 200, uptime: 10 * second)
        counter.observe(joules: 300, uptime: 20 * second)     // 10 W
        counter.observe(joules: 5, uptime: 30 * second)       // went backwards
        XCTAssertNil(counter.current(at: 30 * second, maxAge: 600 * second))
    }

    // MARK: temperatures

    func testTemperatureTestsCoverTheGroupRules() {
        XCTAssertEqual(SensorMath.temperatureKind(for: "PMU tdie3"), .cpu)
        XCTAssertEqual(SensorMath.temperatureKind(for: "PMU pACC0"), .cpu)
        XCTAssertEqual(SensorMath.temperatureKind(for: "GPU die"), .gpu)
        XCTAssertNil(SensorMath.temperatureKind(for: "PMU tdev1"), "device sensors are neither CPU nor GPU")
        XCTAssertNil(SensorMath.temperatureKind(for: "NAND CH0 temp"))
    }

    func testTemperaturePlausibility() {
        XCTAssertTrue(SensorMath.isPlausibleCelsius(58.4))
        XCTAssertFalse(SensorMath.isPlausibleCelsius(0))
        XCTAssertFalse(SensorMath.isPlausibleCelsius(151))
        XCTAssertFalse(SensorMath.isPlausibleCelsius(.nan))
    }

    func testGroupAverageUsesNamesButMaxUsesRawReadings() {
        // Three names, one of them read twice; the raw max (71) is hotter than any name mean.
        let group = SensorMath.group(means: [50, 60, 55], rawMax: 71)
        XCTAssertEqual(group?.average ?? -1, 55, accuracy: 1e-9)
        XCTAssertEqual(group?.max, 71)
        XCTAssertEqual(group?.sensors, 3)
        XCTAssertNil(SensorMath.group(means: [], rawMax: nil))
    }

    func testHeatLevelThresholdsForTheMenuBarDot() {
        XCTAssertEqual(HeatLevel(celsius: 45), .normal)
        XCTAssertEqual(HeatLevel(celsius: 69.9), .normal)
        XCTAssertEqual(HeatLevel(celsius: 70), .warm)
        XCTAssertEqual(HeatLevel(celsius: 89.9), .warm)
        XCTAssertEqual(HeatLevel(celsius: 90), .hot)
        XCTAssertEqual(HeatLevel(celsius: 104), .hot)
    }
}
