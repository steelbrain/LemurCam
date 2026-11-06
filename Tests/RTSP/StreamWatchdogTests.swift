@testable import LemurCam
import XCTest

/// Locks the stream watchdog's stall decisions. It used to watch only packet
/// arrival, so a stream whose frames kept arriving but never decoded (a failed
/// decoder session or format description) stayed "streaming" with the picture
/// frozen. It now also reports a decode stall, raised as an error into the normal
/// retry path, but only when a keyframe arrived and still nothing decoded: waiting
/// for a keyframe (at stream start or after packet loss) is normal with long
/// keyframe intervals and must never reconnect. Times are injected; nothing sleeps.
internal final class StreamWatchdogTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000
    private let start: UInt64 = 1_000_000_000_000
    private let dataTimeout: UInt64 = 10 * 1_000_000_000
    private let decodeTimeout: UInt64 = 20 * 1_000_000_000

    private func check(_ watchdog: StreamWatchdog, at now: UInt64) -> StreamWatchdog.Stall? {
        watchdog.checkForStall(now: now, dataTimeout: dataTimeout, decodeTimeout: decodeTimeout)
    }

    func testProgressingStreamDoesNotStall() {
        let watchdog = StreamWatchdog(now: start)
        for tick in 1...60 {
            let now = start + UInt64(tick) * second
            watchdog.markFrameReceived(isKeyframe: tick.isMultiple(of: 30), now: now)
            watchdog.markFrameDecoded()
            XCTAssertNil(check(watchdog, at: now))
        }
        XCTAssertNil(watchdog.stall)
    }

    func testNoFramesIsADataStall() {
        let watchdog = StreamWatchdog(now: start)

        XCTAssertNil(check(watchdog, at: start + dataTimeout - 1))
        XCTAssertEqual(check(watchdog, at: start + dataTimeout), .noData)
    }

    /// A keyframe arrived and frames keep arriving, but nothing decodes: the decoder
    /// or its format description failed. This used to stay frozen forever.
    func testKeyframeWithoutDecodedVideoIsADecodeStall() {
        let watchdog = StreamWatchdog(now: start)
        let keyframeAt = start + second
        watchdog.markFrameReceived(isKeyframe: true, now: keyframeAt)
        var now = keyframeAt
        while now < keyframeAt + decodeTimeout - second {
            now += second
            watchdog.markFrameReceived(now: now)
            XCTAssertNil(check(watchdog, at: now), "no stall before the decode timeout")
        }

        now = keyframeAt + decodeTimeout
        watchdog.markFrameReceived(now: now)
        XCTAssertEqual(check(watchdog, at: now), .noDecodedVideo)
    }

    /// A camera with a long keyframe interval, joined mid-GOP: non-key frames arrive
    /// for a long time and nothing decodes yet. That's waiting, not a broken decoder.
    func testWaitingForTheFirstKeyframeIsNotADecodeStall() {
        let watchdog = StreamWatchdog(now: start)
        for tick in 1...90 {
            let now = start + UInt64(tick) * second
            watchdog.markFrameReceived(now: now)
            XCTAssertNil(check(watchdog, at: now), "a long wait for a keyframe must not reconnect")
        }
    }

    /// After packet loss the pipeline drops frames until the next keyframe, so the
    /// picture freezes for up to a keyframe interval. That must not reconnect either.
    func testFreezeAfterLossUntilTheNextKeyframeIsNotADecodeStall() {
        let watchdog = StreamWatchdog(now: start)
        watchdog.markFrameReceived(isKeyframe: true, now: start + second)
        watchdog.markFrameDecoded()

        for tick in 2...60 {
            let now = start + UInt64(tick) * second
            watchdog.markFrameReceived(now: now)
            XCTAssertNil(check(watchdog, at: now))
        }

        let nextKeyframe = start + 61 * second
        watchdog.markFrameReceived(isKeyframe: true, now: nextKeyframe)
        watchdog.markFrameDecoded()
        let later = nextKeyframe + decodeTimeout
        watchdog.markFrameReceived(now: later)
        XCTAssertNil(check(watchdog, at: later))
    }

    /// The clock runs from the first keyframe still waiting for a picture; later
    /// keyframes that also fail to decode don't restart it.
    func testDecodeStallCountsFromTheFirstUndecodedKeyframe() {
        let watchdog = StreamWatchdog(now: start)
        watchdog.markFrameReceived(isKeyframe: true, now: start + second)
        watchdog.markFrameDecoded()

        let failingKeyframe = start + 30 * second
        watchdog.markFrameReceived(isKeyframe: true, now: failingKeyframe)
        let laterKeyframe = failingKeyframe + 10 * second
        watchdog.markFrameReceived(isKeyframe: true, now: laterKeyframe)

        let beforeTimeout = failingKeyframe + decodeTimeout - second
        watchdog.markFrameReceived(now: beforeTimeout)
        XCTAssertNil(check(watchdog, at: beforeTimeout))

        let atTimeout = failingKeyframe + decodeTimeout
        watchdog.markFrameReceived(now: atTimeout)
        XCTAssertEqual(check(watchdog, at: atTimeout), .noDecodedVideo)
    }

    /// Without frames there is nothing to decode, so the data stall wins.
    func testDataStallTakesPrecedence() {
        let watchdog = StreamWatchdog(now: start)
        watchdog.markFrameReceived(isKeyframe: true, now: start)

        XCTAssertEqual(check(watchdog, at: start + decodeTimeout), .noData)
    }

    func testStallIsSticky() {
        let watchdog = StreamWatchdog(now: start)
        XCTAssertEqual(check(watchdog, at: start + dataTimeout), .noData)

        let later = start + dataTimeout + second
        watchdog.markFrameReceived(isKeyframe: true, now: later)
        watchdog.markFrameDecoded()

        XCTAssertEqual(check(watchdog, at: later), .noData)
        XCTAssertEqual(watchdog.stall, .noData)
    }

    /// A frame marked after the checker read the clock must not underflow.
    func testMarkLaterThanTheCheckTimeIsNotAStall() {
        let watchdog = StreamWatchdog(now: start)
        watchdog.markFrameReceived(isKeyframe: true, now: start + 5 * second)

        XCTAssertNil(check(watchdog, at: start + 4 * second))
    }

    func testStallsMapToTheirErrors() {
        XCTAssertTrue(StreamWatchdog.Stall.noData.error is RTSPStreamPipeline.StreamStallError)
        XCTAssertTrue(StreamWatchdog.Stall.noDecodedVideo.error is RTSPStreamPipeline.VideoDecodeStallError)
    }
}
