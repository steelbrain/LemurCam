@testable import LemurCam
import XCTest

/// Pins the sink-stream consume re-arm policy. The extension's
/// `consumeSampleBuffer` loop must re-arm immediately only when a buffer was
/// delivered; an empty completion must be throttled to one frame interval so the
/// pull does not become a busy XPC poll that pegs CPU in both processes. These
/// are the exact branches that regressed into the 27-30% in-use CPU.
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

    func testEmptyCompletionThrottlesByOneFrameInterval() {
        XCTAssertEqual(
            SinkConsumeScheduler.action(hasBuffer: false, hasError: false, frameRate: 60),
            .resubscribeAfter(nanoseconds: 16_666_666)
        )
        XCTAssertEqual(
            SinkConsumeScheduler.action(hasBuffer: false, hasError: false, frameRate: 30),
            .resubscribeAfter(nanoseconds: 33_333_333)
        )
    }

    // MARK: - emptyPollDelayNanoseconds()

    func testDelayIsOneFrameInterval() {
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 60), 16_666_666)
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 30), 33_333_333)
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 1), 1_000_000_000)
    }

    func testDelayClampsNonPositiveFrameRate() {
        // A zero/garbage stored frame rate must never divide by zero or yield a
        // zero delay (which would reinstate the busy poll).
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: 0), 1_000_000_000)
        XCTAssertEqual(SinkConsumeScheduler.emptyPollDelayNanoseconds(frameRate: -5), 1_000_000_000)
    }
}
