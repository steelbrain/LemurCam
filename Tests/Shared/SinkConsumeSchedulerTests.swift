@testable import LemurCam
import XCTest

/// Pins the sink-stream consume re-arm policy. The extension's
/// `consumeSampleBuffer` loop must re-arm immediately only when a buffer was
/// delivered; an empty completion must be throttled to a fraction of a frame
/// interval so the pull does not become a busy XPC poll that pegs CPU in both
/// processes. These are the exact branches that regressed into the 27-30% in-use
/// CPU. The fraction is `Tuning.sinkEmptyPollsPerFrame` (two): at 60 fps a frame
/// waits under half a frame in the app's queue, which the extension's pacing absorbs.
internal final class SinkConsumeSchedulerTests: XCTestCase {

    // MARK: - action()

    func testErrorStopsTheLoop() {
        XCTAssertEqual(
            SinkConsumeScheduler.action(hasBuffer: false, hasError: true, frameRate: 60),
            .stop
        )
        // An error wins even if a buffer is somehow also present.
        XCTAssertEqual(
            SinkConsumeScheduler.action(hasBuffer: true, hasError: true, frameRate: 60),
            .stop
        )
    }

    func testBufferReArmsImmediately() {
        XCTAssertEqual(
            SinkConsumeScheduler.action(hasBuffer: true, hasError: false, frameRate: 60),
            .resubscribeImmediately
        )
    }

    func testEmptyCompletionThrottlesByHalfAFrameInterval() {
        XCTAssertEqual(
            SinkConsumeScheduler.action(hasBuffer: false, hasError: false, frameRate: 60),
            .resubscribeAfter(nanoseconds: 8_333_333)
        )
        XCTAssertEqual(
            SinkConsumeScheduler.action(hasBuffer: false, hasError: false, frameRate: 30),
            .resubscribeAfter(nanoseconds: 16_666_666)
        )
    }

    // MARK: - emptyPollDelayNanoseconds()

    func testDelayIsHalfAFrameInterval() {
        XCTAssertEqual(Tuning.sinkEmptyPollsPerFrame, 2)
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 60), 8_333_333)
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 30), 16_666_666)
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 1), 500_000_000)
    }

    func testDelayClampsNonPositiveFrameRate() {
        // A zero/garbage stored frame rate must never divide by zero or yield a
        // zero delay (which would reinstate the busy poll).
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 0), 500_000_000)
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: -5), 500_000_000)
    }
}
