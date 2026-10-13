import XCTest
@testable import Nora

final class StatusSensorMathTests: XCTestCase {
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

    func testStuckCPUCounterIsUnavailableButZeroGPUAndANEAreNumbers() {
        let reading = PowerSampler.reading(from: [
            EnergyChannel(name: "CPU Energy", unit: "mJ", value: 0),
            EnergyChannel(name: "GPU Energy", unit: "nJ", value: 500_000_000),
            EnergyChannel(name: "ANE0", unit: "mJ", value: 0),
        ], seconds: 1)
        XCTAssertNil(reading.cpu)
        XCTAssertEqual(reading.gpu ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reading.ane, 0)
        XCTAssertNil(reading.total, "a total without the CPU would understate the power")
    }

    func testCPUWattsAndTotalWhenAllComponentsAreKnown() {
        let reading = PowerSampler.reading(from: [
            EnergyChannel(name: "CPU Energy", unit: "mJ", value: 2_000),
            EnergyChannel(name: "GPU Energy", unit: "mJ", value: 1_000),
            EnergyChannel(name: "ANE0", unit: "mJ", value: 500),
        ], seconds: 2)
        XCTAssertEqual(reading.cpu ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(reading.gpu ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reading.ane ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(reading.total ?? -1, 1.75, accuracy: 1e-9)
    }

    func testComponentWithAnUnknownUnitIsDroppedNotGuessed() {
        let reading = PowerSampler.reading(from: [
            EnergyChannel(name: "GPU Energy", unit: "bogus", value: 1_000),
            EnergyChannel(name: "CPU Energy", unit: "mJ", value: 1_000),
        ], seconds: 1)
        XCTAssertNil(reading.gpu)
        XCTAssertEqual(reading.cpu ?? -1, 1, accuracy: 1e-9)
    }

    func testTemperatureSensorsGroupIntoCPUAndGPU() {
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

    func testTemperatureGroupAverageMaxAndCount() {
        let group = SensorMath.group([50, 60, 70])
        XCTAssertEqual(group?.average ?? -1, 60, accuracy: 1e-9)
        XCTAssertEqual(group?.max, 70)
        XCTAssertEqual(group?.sensors, 3)
        XCTAssertNil(SensorMath.group([]))
    }
}
