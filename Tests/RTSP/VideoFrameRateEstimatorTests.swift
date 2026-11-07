@testable import LemurCam
import XCTest

/// Pins how the pipeline measures a camera's frame rate, which the jitter buffer
/// drains at. It reads the frames' timestamps (derived from RTP), not when they
/// arrive: a camera stalls for a keyframe and then sends a burst.
internal final class VideoFrameRateEstimatorTests: XCTestCase {
    /// Feeds `timestamps` and returns every rate reported, in order.
    private func reports(_ timestamps: [Double], into estimator: inout VideoFrameRateEstimator) -> [Double] {
        timestamps.compactMap { estimator.record(timestamp: $0) }
    }

    private func reports(_ timestamps: [Double]) -> [Double] {
        var estimator = VideoFrameRateEstimator()
        return reports(timestamps, into: &estimator)
    }

    private func frames(_ count: Int, fps: Double, from start: Double = 1000) -> [Double] {
        (0..<count).map { start + Double($0) / fps }
    }

    func testCommonRatesAreReportedOnceKnown() {
        for fps in [10.0, 15, 20, 25, 30, 50, 60] {
            XCTAssertEqual(reports(frames(300, fps: fps)), [fps], "\(fps) fps")
        }
    }

    /// NTSC rates come out as the whole number the virtual camera offers.
    func testNTSCRatesRoundToTheWholeNumber() {
        XCTAssertEqual(reports(frames(300, fps: 30_000.0 / 1001)), [30])
        XCTAssertEqual(reports(frames(300, fps: 60_000.0 / 1001)), [60])
    }

    func testARateFarFromAWholeNumberIsKept() {
        let reported = reports(frames(100, fps: 12.5))
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first ?? 0, 12.5, accuracy: 1e-6)
    }

    func testTheRateIsKnownAfterTheMinimumFrames() {
        var estimator = VideoFrameRateEstimator()
        let timestamps = frames(Tuning.frameRateMinimumFrames, fps: 60)
        XCTAssertEqual(reports(Array(timestamps.dropLast()), into: &estimator), [])
        XCTAssertEqual(estimator.record(timestamp: timestamps[timestamps.count - 1]), 60)
        XCTAssertEqual(estimator.reportedRate, 60)
    }

    /// A lost frame leaves a double gap, which counts as two frames.
    func testLostFramesDoNotLowerTheRate() {
        let kept = frames(600, fps: 60).enumerated().filter { !$0.offset.isMultiple(of: 7) }.map(\.element)
        XCTAssertEqual(reports(kept), [60])
    }

    /// B-frames arrive in decode order, not time order.
    func testFramesOutOfOrderGiveTheRate() {
        let order = [0, 3, 1, 2, 6, 4, 5, 9, 7, 8]
        let timestamps = (0..<30).flatMap { group in order.map { 1000 + Double(group * 10 + $0) / 30 } }
        XCTAssertEqual(reports(timestamps), [30])
    }

    /// A camera stamping frames from its wall clock adds jitter. A few frames give a
    /// rough first rate; a whole window settles it.
    func testJitteredTimestampsSettleOnTheRate() {
        var estimator = VideoFrameRateEstimator()
        let jittered = frames(600, fps: 60).enumerated().map { index, time in
            time + (index.isMultiple(of: 2) ? 0.002 : -0.002)
        }
        let reported = reports(jittered, into: &estimator)
        XCTAssertEqual(reported.last, 60)
        XCTAssertLessThanOrEqual(reported.count, 3, "\(reported)")
        XCTAssertEqual(reported.first ?? 0, 60, accuracy: 60 * 0.06, "the first estimate is close")
    }

    /// Wall-clock stamps spread at random, not alternating.
    func testRandomlyJitteredTimestampsSettleOnTheRate() {
        var estimator = VideoFrameRateEstimator()
        let jittered = frames(900, fps: 30).enumerated().map { index, time in
            let mixed = (UInt64(index) &+ 0x9E37_79B9_7F4A_7C15) &* 0xBF58_476D_1CE4_E5B9
            return time + (Double((mixed >> 33) % 7001) - 3500) / 1_000_000
        }
        let reported = reports(jittered, into: &estimator)
        XCTAssertEqual(reported.last, 30)
        XCTAssertEqual(estimator.reportedRate, 30)
    }

    func testAChangeIsReportedOnceTheWindowHoldsTheNewRate() {
        var estimator = VideoFrameRateEstimator()
        XCTAssertEqual(reports(frames(120, fps: 30), into: &estimator), [30])
        let after = 1000 + 120.0 / 30
        let reported = reports(frames(120, fps: 60, from: after), into: &estimator)
        XCTAssertEqual(reported.last, 60, "\(reported)")
        XCTAssertEqual(estimator.reportedRate, 60)
    }

    /// A drift within the settled threshold doesn't re-arm the drain timer.
    func testASmallDriftIsNotReported() {
        var estimator = VideoFrameRateEstimator()
        XCTAssertEqual(reports(frames(120, fps: 12.5), into: &estimator).count, 1)
        XCTAssertEqual(reports(frames(120, fps: 12.45, from: 1010), into: &estimator), [])
    }

    /// A jump (the camera restarted its clock) starts the measurement over instead of
    /// counting the jump as a gap.
    func testAJumpInTheTimestampsStartsOver() {
        var estimator = VideoFrameRateEstimator()
        XCTAssertEqual(reports(frames(60, fps: 30), into: &estimator), [30])
        XCTAssertEqual(reports(frames(60, fps: 30, from: 50_000), into: &estimator), [])
        XCTAssertEqual(reports(frames(60, fps: 15, from: 3), into: &estimator), [15])
    }

    func testUnusableTimestampsReportNothing() {
        XCTAssertEqual(reports(Array(repeating: 1000, count: 100)), [], "no gap between frames")
        XCTAssertEqual(reports([.nan, .infinity, -.infinity]), [])
        XCTAssertNil(VideoFrameRateEstimator.rate(of: []))
        XCTAssertNil(VideoFrameRateEstimator.rate(of: [5]))
    }
}
