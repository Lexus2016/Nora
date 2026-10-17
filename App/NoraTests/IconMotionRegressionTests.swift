import SwiftUI
import XCTest
@testable import Nora

/// Policy and geometry checks, not a CPU/GPU benchmark or a native animation trace.
final class IconMotionRegressionTests: XCTestCase {
    func testMotionRequiresActiveVisibleWindowWithoutReduceMotion() {
        for active in [ControlActiveState.active, .key] {
            XCTAssertTrue(DecorativeMotion.isAllowed(reduceMotion: false, activeState: active))
            XCTAssertFalse(DecorativeMotion.isAllowed(reduceMotion: true, activeState: active))
            XCTAssertFalse(DecorativeMotion.isAllowed(reduceMotion: false, activeState: active, visible: false))
        }
        XCTAssertFalse(DecorativeMotion.isAllowed(reduceMotion: false, activeState: .inactive))
    }

    func testBusyGlassHasSixSideLayersAndIdleAddsNone() {
        XCTAssertEqual(GlassMotion.sideLayers(amplitude: 0), 0)
        XCTAssertEqual(GlassMotion.sideLayers(amplitude: 9), 0)
        XCTAssertEqual(GlassMotion.sideLayers(amplitude: 26), 6)
        XCTAssertEqual(GlassMotion.sideLayers(amplitude: -26), 6)
        XCTAssertEqual(GlassMotion.maximumFramesPerSecond, 24)
    }

    func testGlassMotionStaysInsideItsGeometryBudget() {
        for time in stride(from: 0.0, through: 30.0, by: 0.05) {
            for amplitude in [0.0, 9, 26, 100] {
                let pose = GlassMotion.pose(time: time, amplitude: amplitude, period: 3.2)
                XCTAssertLessThanOrEqual(abs(pose.angle), 18.00001)
                XCTAssertLessThanOrEqual(abs(pose.tilt), 1.60001)
                XCTAssertLessThanOrEqual(abs(pose.lift), 1.80001)
            }
        }
    }

    func testGlassMotionUsesMinimumPeriodAndDeterministicPhases() {
        let quarter = GlassMotion.minimumPeriod / 4
        XCTAssertEqual(GlassMotion.pose(time: quarter, amplitude: 26, period: 0).angle, 18, accuracy: 0.00001)
        let first = GlassMotion.pose(time: 1.2, amplitude: 9, period: 7)
        XCTAssertEqual(first, GlassMotion.pose(time: 1.2, amplitude: 9, period: 7))
        let nextCycle = GlassMotion.pose(time: 8.2, amplitude: 9, period: 7)
        XCTAssertEqual(first.angle, nextCycle.angle, accuracy: 0.00001)
        XCTAssertEqual(first.tilt, nextCycle.tilt, accuracy: 0.00001)
        XCTAssertEqual(first.lift, nextCycle.lift, accuracy: 0.00001)
    }

    func testZeroAmplitudeAndRestPoseStayStill() {
        XCTAssertEqual(GlassMotion.pose(time: 2.1, amplitude: 0, period: 7), GlassMotion.Pose(angle: 0, tilt: 0, lift: 0))
        XCTAssertEqual(GlassMotion.Pose.rest.lift, 0)
        XCTAssertLessThanOrEqual(abs(GlassMotion.Pose.rest.angle), 4)
    }

    func testMascotHasExactlyTwoWavesThenRestWithinOneSecond() {
        XCTAssertEqual(TrashMascotMotion.steps.map(\.angle), [-18, 18, -18, 18, 0])
        XCTAssertEqual(TrashMascotMotion.steps.filter { $0.angle == 18 }.count, 2)
        XCTAssertEqual(TrashMascotMotion.steps.last?.angle, 0)
        XCTAssertEqual(TrashMascotMotion.duration, 0.9, accuracy: 0.00001)
        XCTAssertTrue(TrashMascotMotion.steps.allSatisfy { $0.duration > 0 && abs($0.angle) <= 18 })
    }
}
