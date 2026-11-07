@testable import LemurCam
import XCTest

/// Pins how the camera extension paces the app's frames to the active frame rate.
/// A camera faster than the rate an app chose must come out at that rate, and a
/// camera at the chosen rate must come out whole. Its frames reach the extension
/// with jitter: the app's drain timer, the extension's poll for frames (up to half a
/// frame at 60 fps) and two processes. The pacer this replaced held frames to fixed
/// slots, so a late frame moved every later slot and a frame on time was dropped as
/// early; at 60 fps that cost frames all the time.
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

    /// A deterministic spread of `-bound...bound` nanoseconds, the same for every run.
    private func pseudoRandomJitter(bound: Int64) -> (Int) -> Int64 {
        { index in
            let mixed = (UInt64(index) &+ 0x9E37_79B9_7F4A_7C15) &* 0xBF58_476D_1CE4_E5B9
            return Int64((mixed >> 33) % UInt64(2 * bound + 1)) - bound
        }
    }

    func testTheFirstFrameIsSent() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: start, frameDurationNanoseconds: fps30))
        XCTAssertEqual(pacer.lastNanoseconds, start)
    }

    /// Credit for one more frame is there from the start; past that, a frame right
    /// after a sent one is dropped.
    func testAtMostTheBurstGoesOutBackToBack() {
        var pacer = FramePacer()
        let sent = (0..<6).filter { offset in
            pacer.admit(atNanoseconds: start + UInt64(offset) * 1_000_000, frameDurationNanoseconds: fps30)
        }
        XCTAssertEqual(sent.count, Int(Tuning.framePacingBurst))
    }

    func testAThirtyFPSCameraAtThirtyFPSKeepsEveryFrame() {
        XCTAssertEqual(sentCount(frames: 300, every: fps30, duration: fps30), 300)
    }

    func testASixtyFPSCameraAtSixtyFPSKeepsEveryFrame() {
        XCTAssertEqual(sentCount(frames: 600, every: fps60, duration: fps60), 600)
    }

    /// The app's drain timer has a few milliseconds of leeway, and frames cross two
    /// processes on their way to the extension.
    func testAJitteryThirtyFPSCameraAtThirtyFPSKeepsEveryFrame() {
        let jitter: (Int) -> Int64 = { index in index.isMultiple(of: 2) ? -5_000_000 : 5_000_000 }
        XCTAssertEqual(sentCount(frames: 300, every: fps30, duration: fps30, jitter: jitter), 300)
    }

    /// The extension polls for frames every half frame at 60 fps, so a frame can wait
    /// up to 8.3 ms, and the app's drain timer adds its own. The slot schedule lost
    /// frames here once a late frame had moved its slots.
    func testAJitterySixtyFPSCameraAtSixtyFPSKeepsEveryFrame() {
        let jitter = pseudoRandomJitter(bound: 7_000_000)
        XCTAssertEqual(sentCount(frames: 3600, every: fps60, duration: fps60, jitter: jitter), 3600)
    }

    /// A frame a whole frame late, then the next on time right behind it.
    func testALateFrameAndTheOneRightBehindItBothGoOut() {
        let jitter: (Int) -> Int64 = { index in index.isMultiple(of: 10) ? Int64(self.fps60) - 1_000_000 : 0 }
        XCTAssertEqual(sentCount(frames: 600, every: fps60, duration: fps60, jitter: jitter), 600)
    }

    func testASlightlySlowCameraAtThirtyFPSKeepsEveryFrame() {
        let ntsc: UInt64 = 33_366_667 // 29.97 fps
        XCTAssertEqual(sentCount(frames: 300, every: ntsc, duration: fps30), 300)
    }

    /// Beyond the burst at the start, a faster camera comes out at the active rate.
    func testASixtyFPSCameraAtThirtyFPSSendsHalf() {
        XCTAssertEqual(Double(sentCount(frames: 600, every: fps60, duration: fps30)), 300, accuracy: 2)
    }

    func testAJitterySixtyFPSCameraAtThirtyFPSSendsHalf() {
        let jitter = pseudoRandomJitter(bound: 7_000_000)
        XCTAssertEqual(Double(sentCount(frames: 600, every: fps60, duration: fps30, jitter: jitter)), 300, accuracy: 2)
    }

    /// 50 fps doesn't divide into 30; the average still holds at 30.
    func testAFiftyFPSCameraAtThirtyFPSAveragesThirty() {
        let sent = sentCount(frames: 500, every: 20_000_000, duration: fps30)
        XCTAssertEqual(Double(sent), 300, accuracy: 3)
    }

    /// A camera a little faster than the active rate loses a frame only now and then.
    func testACameraJustAboveTheRateLosesOnlyTheExcess() {
        let fast: UInt64 = 1_000_000_000 / 61
        let sent = sentCount(frames: 610, every: fast, duration: fps60)
        XCTAssertEqual(Double(sent), 600, accuracy: 2)
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
        XCTAssertEqual(sent, Array(burst.prefix(Int(Tuning.framePacingBurst))))
    }

    func testAZeroDurationPacesNothing() {
        var pacer = FramePacer()
        for offset in 0..<10 {
            XCTAssertTrue(pacer.admit(atNanoseconds: start + UInt64(offset), frameDurationNanoseconds: 0))
        }
    }

    func testResetSendsTheNextFrameWheneverItComes() {
        var pacer = FramePacer()
        for offset in 0..<3 {
            _ = pacer.admit(atNanoseconds: start + UInt64(offset), frameDurationNanoseconds: fps30)
        }
        XCTAssertFalse(pacer.admit(atNanoseconds: start + 3, frameDurationNanoseconds: fps30))
        pacer.reset()
        XCTAssertNil(pacer.lastNanoseconds)
        XCTAssertTrue(pacer.admit(atNanoseconds: start + 4, frameDurationNanoseconds: fps30))
    }

    /// A time earlier than the last one earns nothing and doesn't move the clock back.
    func testATimeBeforeTheLastEarnsNoCredit() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: start, frameDurationNanoseconds: fps30))
        XCTAssertTrue(pacer.admit(atNanoseconds: start - 1_000_000, frameDurationNanoseconds: fps30))
        XCTAssertFalse(pacer.admit(atNanoseconds: start - 2_000_000, frameDurationNanoseconds: fps30))
        XCTAssertEqual(pacer.lastNanoseconds, start)
    }

    /// Arithmetic that overflowed would trap and take the extension down.
    func testTimesNearTheClocksEndDoNotOverflow() {
        var pacer = FramePacer()
        XCTAssertTrue(pacer.admit(atNanoseconds: .max - 10, frameDurationNanoseconds: fps30))
        _ = pacer.admit(atNanoseconds: .max, frameDurationNanoseconds: .max)
        XCTAssertEqual(pacer.lastNanoseconds, .max)
    }

    func testTheBurstIsAFewFrames() {
        XCTAssertGreaterThanOrEqual(Tuning.framePacingBurst, 2, "a camera at the active rate would lose frames")
        XCTAssertLessThanOrEqual(Tuning.framePacingBurst, 4, "a stall's catch-up would go out as a burst")
        XCTAssertGreaterThan(Tuning.frameDurationMatchTolerance, 0)
        XCTAssertLessThan(Tuning.frameDurationMatchTolerance, 0.1)
    }
}
