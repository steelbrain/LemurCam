@testable import LemurCam
import XCTest

/// Pins that the jitter buffer keeps the same windows in time at any drain rate. At
/// the old fixed 30 fps a 60 fps camera filled the 16-frame buffer, lost every other
/// frame to its capacity, and ran about half a second behind.
internal final class JitterBufferSizingTests: XCTestCase {
    func testTheDefaultRateUsesTheTunedCounts() {
        let sizing = JitterBufferSizing(drainFPS: Tuning.jitterBufferDefaultDrainFPS)
        XCTAssertEqual(sizing.capacity, Tuning.jitterBufferCapacity)
        XCTAssertEqual(sizing.primingThreshold, Tuning.jitterBufferPrimingThreshold)
        XCTAssertEqual(
            sizing.catchUpWindowTicks, Int(Tuning.jitterBufferCatchUpWindow * Tuning.jitterBufferDefaultDrainFPS)
        )
        XCTAssertEqual(sizing.drainInterval, 1 / Tuning.jitterBufferDefaultDrainFPS, accuracy: 1e-12)
    }

    func testSixtyFPSHoldsTwiceTheFramesForTheSameTime() {
        let sizing = JitterBufferSizing(drainFPS: 60)
        XCTAssertEqual(sizing.drainFPS, 60)
        XCTAssertEqual(sizing.capacity, 2 * Tuning.jitterBufferCapacity)
        XCTAssertEqual(sizing.primingThreshold, 2 * Tuning.jitterBufferPrimingThreshold)
        XCTAssertEqual(sizing.catchUpWindowTicks, Int(Tuning.jitterBufferCatchUpWindow * 60))
    }

    func testTheWindowsStayTheSameLengthInTime() {
        let reference = JitterBufferSizing(drainFPS: Tuning.jitterBufferDefaultDrainFPS)
        let smoothing = Double(reference.capacity) / reference.drainFPS
        let priming = Double(reference.primingThreshold) / reference.drainFPS
        for fps in [15.0, 20, 24, 25, 30, 50, 60] {
            let sizing = JitterBufferSizing(drainFPS: fps)
            XCTAssertEqual(Double(sizing.capacity) / fps, smoothing, accuracy: 0.5 / fps, "\(fps) fps")
            XCTAssertEqual(Double(sizing.primingThreshold) / fps, priming, accuracy: 0.5 / fps, "\(fps) fps")
            XCTAssertLessThan(sizing.primingThreshold, sizing.capacity, "\(fps) fps")
        }
    }

    /// A very slow camera still primes on its first frame and holds more than that.
    func testASlowCameraStillPrimesAndBuffers() {
        let sizing = JitterBufferSizing(drainFPS: Tuning.jitterBufferMinDrainFPS)
        XCTAssertEqual(sizing.primingThreshold, 1)
        XCTAssertEqual(sizing.capacity, 2)
        XCTAssertGreaterThanOrEqual(sizing.catchUpWindowTicks, 1)
    }

    func testTheRateIsHeldToTheLimits() {
        XCTAssertEqual(JitterBufferSizing(drainFPS: 120).drainFPS, Tuning.jitterBufferMaxDrainFPS)
        XCTAssertEqual(JitterBufferSizing(drainFPS: 0.2).drainFPS, Tuning.jitterBufferMinDrainFPS)
        XCTAssertEqual(JitterBufferSizing(drainFPS: 0).drainFPS, Tuning.jitterBufferMinDrainFPS)
        XCTAssertEqual(JitterBufferSizing(drainFPS: -30).drainFPS, Tuning.jitterBufferMinDrainFPS)
        XCTAssertEqual(JitterBufferSizing(drainFPS: .nan).drainFPS, Tuning.jitterBufferDefaultDrainFPS)
        XCTAssertEqual(JitterBufferSizing(drainFPS: .infinity).drainFPS, Tuning.jitterBufferDefaultDrainFPS)
    }

    func testAnOverriddenCatchUpWindowHoldsAtEveryRate() {
        XCTAssertEqual(JitterBufferSizing(drainFPS: 30, catchUpWindowTicks: 3).catchUpWindowTicks, 3)
        XCTAssertEqual(JitterBufferSizing(drainFPS: 60, catchUpWindowTicks: 3).catchUpWindowTicks, 3)
        XCTAssertEqual(JitterBufferSizing(drainFPS: 60, catchUpWindowTicks: 0).catchUpWindowTicks, 1)
    }
}
