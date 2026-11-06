@testable import LemurCam
import XCTest

/// Locks the stream watchdog's stall decisions. It used to watch only packet
/// arrival, so a stream whose frames kept arriving but never decoded (a failed
/// decoder session or format description) stayed "streaming" with the picture
/// frozen. It now also reports a decode stall, which the pipeline raises as an error
/// into the normal retry path. Times are injected, so nothing here sleeps.
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
            watchdog.markFrameReceived(now: now)
            watchdog.markFrameDecoded(now: now)
            XCTAssertNil(check(watchdog, at: now))
        }
        XCTAssertNil(watchdog.stall)
    }

    func testNoFramesIsADataStall() {
        let watchdog = StreamWatchdog(now: start)

        XCTAssertNil(check(watchdog, at: start + dataTimeout - 1))
        XCTAssertEqual(check(watchdog, at: start + dataTimeout), .noData)
    }

    /// Frames arriving without a decoded picture: the case that used to stay frozen.
    func testFramesWithoutDecodedVideoIsADecodeStall() {
        let watchdog = StreamWatchdog(now: start)
        var now = start
        while now < start + decodeTimeout - second {
            now += second
            watchdog.markFrameReceived(now: now)
            XCTAssertNil(check(watchdog, at: now), "no stall before the decode timeout")
        }

        now = start + decodeTimeout
        watchdog.markFrameReceived(now: now)
        XCTAssertEqual(check(watchdog, at: now), .noDecodedVideo)
    }

    /// Decoding that stops mid-stream counts from the last decoded frame.
    func testDecodeStallCountsFromTheLastDecodedFrame() {
        let watchdog = StreamWatchdog(now: start)
        let lastDecode = start + 30 * second
        watchdog.markFrameReceived(now: lastDecode)
        watchdog.markFrameDecoded(now: lastDecode)

        let beforeTimeout = lastDecode + decodeTimeout - second
        watchdog.markFrameReceived(now: beforeTimeout)
        XCTAssertNil(check(watchdog, at: beforeTimeout))

        let atTimeout = lastDecode + decodeTimeout
        watchdog.markFrameReceived(now: atTimeout)
        XCTAssertEqual(check(watchdog, at: atTimeout), .noDecodedVideo)
    }

    /// Without frames there is nothing to decode, so the data stall wins.
    func testDataStallTakesPrecedence() {
        let watchdog = StreamWatchdog(now: start)

        XCTAssertEqual(check(watchdog, at: start + decodeTimeout), .noData)
    }

    func testStallIsSticky() {
        let watchdog = StreamWatchdog(now: start)
        XCTAssertEqual(check(watchdog, at: start + dataTimeout), .noData)

        let later = start + dataTimeout + second
        watchdog.markFrameReceived(now: later)
        watchdog.markFrameDecoded(now: later)

        XCTAssertEqual(check(watchdog, at: later), .noData)
        XCTAssertEqual(watchdog.stall, .noData)
    }

    /// A frame marked after the checker read the clock must not underflow.
    func testMarkLaterThanTheCheckTimeIsNotAStall() {
        let watchdog = StreamWatchdog(now: start)
        watchdog.markFrameReceived(now: start + 5 * second)
        watchdog.markFrameDecoded(now: start + 5 * second)

        XCTAssertNil(check(watchdog, at: start + 4 * second))
    }

    func testStallsMapToTheirErrors() {
        XCTAssertTrue(StreamWatchdog.Stall.noData.error is RTSPStreamPipeline.StreamStallError)
        XCTAssertTrue(StreamWatchdog.Stall.noDecodedVideo.error is RTSPStreamPipeline.VideoDecodeStallError)
    }

    /// Decoding waits for a keyframe at stream start and after loss, which takes
    /// longer than a gap in packets should, so the decode window must be the longer one.
    func testDecodeTimeoutIsLongerThanTheDataTimeout() {
        XCTAssertGreaterThan(Tuning.videoDecodeStallTimeoutNs, Tuning.streamStallTimeoutNs)
    }
}
