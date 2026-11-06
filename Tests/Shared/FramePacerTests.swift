@testable import LemurCam
import XCTest

/// Pins how the camera extension paces the app's frames to the active frame rate.
/// A camera faster than the rate an app chose must come out at that rate, and a
/// camera at the chosen rate must come out whole: its frames arrive a little early
/// or late, and dropping each early one would halve it.
internal final class FramePacerTests: XCTestCase {
    private let fps30: UInt64 = 1_000_000_000 / 30
    private let fps60: UInt64 = 1_000_000_000 / 60
    private let start: UInt64 = 5_000_000_000

    /// How many of `count` frames, `interval` nanoseconds apart and shifted by
    /// `jitter(i)`, the pacer sends at `duration` per frame.
    private func sentCount(
        frames count: Int,
        every interval: UInt64,
        duration: UInt64,
        jitter: (Int) -> Int64 = { _ in 0 }
    ) -> Int {
        var pacer = FramePacer()
        var sent = 0
        for index in 0..<count {
            let arrival = Int64(start) + Int64(index) * Int64(interval) + jitter(index)
            if pacer.admit(atNanoseconds: UInt64(arrival), frameDurationNanoseconds: duration) {
                sent += 1
            }
        }
        return sent
    }

    func testTheFirstFrameIsSent() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: start, frameDurationNanoseconds: fps30))
        XCTAssertEqual(pacer.nextDueNanoseconds, start + fps30)
    }

    func testAFrameRightAfterASentOneIsDropped() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: start, frameDurationNanoseconds: fps30))
        XCTAssertFalse(pacer.admit(atNanoseconds: start + 1_000_000, frameDurationNanoseconds: fps30))
        XCTAssertFalse(pacer.admit(atNanoseconds: start + fps30 / 2, frameDurationNanoseconds: fps30))
    }

    func testAThirtyFPSCameraAtThirtyFPSKeepsEveryFrame() {
        XCTAssertEqual(sentCount(frames: 300, every: fps30, duration: fps30), 300)
    }

    /// The app's drain timer has a few milliseconds of leeway, and frames cross two
    /// processes on their way to the extension.
    func testAJitteryThirtyFPSCameraAtThirtyFPSKeepsEveryFrame() {
        let jitter: (Int) -> Int64 = { index in index.isMultiple(of: 2) ? -5_000_000 : 5_000_000 }
        XCTAssertEqual(sentCount(frames: 300, every: fps30, duration: fps30, jitter: jitter), 300)
    }

    func testASlightlySlowCameraAtThirtyFPSKeepsEveryFrame() {
        let ntsc: UInt64 = 33_366_667 // 29.97 fps
        XCTAssertEqual(sentCount(frames: 300, every: ntsc, duration: fps30), 300)
    }

    func testASixtyFPSCameraAtThirtyFPSSendsHalf() {
        XCTAssertEqual(sentCount(frames: 600, every: fps60, duration: fps30), 300)
    }

    /// 50 fps doesn't divide into 30; the average still holds at 30.
    func testAFiftyFPSCameraAtThirtyFPSAveragesThirty() {
        let sent = sentCount(frames: 500, every: 20_000_000, duration: fps30)
        XCTAssertEqual(Double(sent), 300, accuracy: 3)
    }

    func testACameraBelowTheRateIsNotThinned() {
        XCTAssertEqual(sentCount(frames: 150, every: fps30, duration: fps60), 150)
        XCTAssertEqual(sentCount(frames: 100, every: 1_000_000_000 / 15, duration: fps30), 100)
    }

    /// After a stall, a burst of late frames must not all go out back to back.
    func testABurstAfterAStallIsNotSentAllAtOnce() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: start, frameDurationNanoseconds: fps30))
        let afterStall = start + 500_000_000
        let burst = (0..<6).map { afterStall + UInt64($0) * 2_000_000 }
        let sent = burst.filter { pacer.admit(atNanoseconds: $0, frameDurationNanoseconds: fps30) }
        XCTAssertEqual(sent, [afterStall])
    }

    func testAZeroDurationPacesNothing() {
        var pacer = FramePacer()
        for offset in 0..<10 {
            XCTAssertTrue(pacer.admit(atNanoseconds: start + UInt64(offset), frameDurationNanoseconds: 0))
        }
    }

    func testResetSendsTheNextFrameWheneverItComes() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: start, frameDurationNanoseconds: fps30))
        pacer.reset()
        XCTAssertNil(pacer.nextDueNanoseconds)
        XCTAssertTrue(pacer.admit(atNanoseconds: start + 1, frameDurationNanoseconds: fps30))
    }

    /// Arithmetic that overflowed would trap and take the extension down.
    func testTimesNearTheClocksEndDoNotOverflow() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: .max - 10, frameDurationNanoseconds: fps30))
        XCTAssertEqual(pacer.nextDueNanoseconds, .max)
        _ = pacer.admit(atNanoseconds: .max - 5, frameDurationNanoseconds: .max)
        XCTAssertEqual(pacer.nextDueNanoseconds, .max)
    }

    func testTheToleranceIsAFractionOfAFrame() {
        XCTAssertGreaterThan(Tuning.framePacingTolerance, 0)
        XCTAssertLessThan(Tuning.framePacingTolerance, 0.5)
        XCTAssertGreaterThan(Tuning.frameDurationMatchTolerance, 0)
        XCTAssertLessThan(Tuning.frameDurationMatchTolerance, 0.1)
    }
}
