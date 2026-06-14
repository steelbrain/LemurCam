@testable import LemurCam
import XCTest

/// Pins the jitter buffer's timing design: it is sized in *time*, not frames. The
/// capacity gives a ~0.5s smoothing window to absorb the ~300-400ms keyframe stalls
/// IP cameras exhibit, and priming a ~0.2s cushion. Raising `jitterBufferDrainFPS`
/// without rescaling capacity/priming would shrink those windows and reintroduce
/// keyframe-stall stutter, so lock the relationship rather than the raw counts.
internal final class JitterBufferTuningTests: XCTestCase {

    func testSmoothingWindowCoversKeyframeStalls() {
        let windowSeconds = Double(Tuning.jitterBufferCapacity) / Tuning.jitterBufferDrainFPS
        XCTAssertGreaterThanOrEqual(windowSeconds, 0.4, "must absorb a ~400ms keyframe stall")
        XCTAssertLessThanOrEqual(windowSeconds, 0.7, "too deep adds latency/memory")
    }

    func testPrimingWindowIsModest() {
        let primingSeconds = Double(Tuning.jitterBufferPrimingThreshold) / Tuning.jitterBufferDrainFPS
        XCTAssertGreaterThanOrEqual(primingSeconds, 0.15, "needs a cushion to avoid immediate underrun")
        XCTAssertLessThanOrEqual(primingSeconds, 0.3, "too high adds start-up latency")
    }

    func testPrimingIsBelowCapacity() {
        XCTAssertLessThan(Tuning.jitterBufferPrimingThreshold, Tuning.jitterBufferCapacity)
    }
}
