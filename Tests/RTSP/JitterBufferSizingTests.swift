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

    /// The default Video Buffer setting is the tuned buffer, at every rate.
    func testTheDefaultSettingChangesNothing() {
        for fps in [1.0, 15, 24, 25, 30, 50, 60] {
            XCTAssertEqual(
                JitterBufferSizing(drainFPS: fps, videoBuffer: .defaultValue), JitterBufferSizing(drainFPS: fps),
                "\(fps) fps"
            )
        }
    }

    /// At 100 ms the start-up cushion and the capacity are half as long in time.
    func testAHundredMillisecondsHoldsHalfAsLong() {
        let thirty = JitterBufferSizing(drainFPS: 30, videoBuffer: .ms100)
        XCTAssertEqual(thirty.primingThreshold, 3)
        XCTAssertEqual(thirty.capacity, 8)
        XCTAssertFalse(thirty.passesThrough)

        let reference = JitterBufferSizing(drainFPS: Tuning.jitterBufferDefaultDrainFPS)
        let smoothing = Double(reference.capacity) / reference.drainFPS / 2
        for fps in [15.0, 20, 24, 25, 30, 50, 60] {
            let sizing = JitterBufferSizing(drainFPS: fps, videoBuffer: .ms100)
            // Rounding to whole frames can land half a frame off: 2.5 frames at 25 fps is 3.
            let halfFrame = 0.5 / fps + 1e-9
            XCTAssertEqual(Double(sizing.primingThreshold) / fps, 0.1, accuracy: halfFrame, "\(fps) fps")
            XCTAssertEqual(Double(sizing.capacity) / fps, smoothing, accuracy: halfFrame, "\(fps) fps")
            XCTAssertLessThan(sizing.primingThreshold, sizing.capacity, "\(fps) fps")
            XCTAssertEqual(sizing.catchUpWindowTicks, JitterBufferSizing(drainFPS: fps).catchUpWindowTicks)
        }
    }

    /// Off holds only the newest frame, which goes on as soon as it comes.
    func testOffPassesFramesThrough() {
        for fps in [1.0, 30, 60] {
            let sizing = JitterBufferSizing(drainFPS: fps, videoBuffer: .off)
            XCTAssertTrue(sizing.passesThrough, "\(fps) fps")
            XCTAssertEqual(sizing.capacity, 1, "\(fps) fps")
            XCTAssertEqual(sizing.drainFPS, fps, "\(fps) fps")
        }
        XCTAssertFalse(JitterBufferSizing(drainFPS: 30).passesThrough)
    }

    func testAnOverriddenCatchUpWindowHoldsAtEveryRate() {
        XCTAssertEqual(JitterBufferSizing(drainFPS: 30, catchUpWindowTicks: 3).catchUpWindowTicks, 3)
        XCTAssertEqual(JitterBufferSizing(drainFPS: 60, catchUpWindowTicks: 3).catchUpWindowTicks, 3)
        XCTAssertEqual(JitterBufferSizing(drainFPS: 60, catchUpWindowTicks: 0).catchUpWindowTicks, 1)
    }
}
