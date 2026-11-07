import CoreVideo
@testable import LemurCam
import os
import XCTest

/// Pins that the jitter buffer drains at the rate it is given: the camera's frame
/// rate, once the pipeline has measured it. It drained at a fixed 30 fps, so a
/// 60 fps camera's frames piled up to the buffer's capacity and every other one was
/// dropped. Timing is checked by the median gap between drains, which a busy
/// machine's late timer firings don't move.
internal final class JitterBufferDrainRateTests: XCTestCase {
    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func enqueue(_ count: Int, into buffer: JitterBuffer) throws {
        for _ in 0..<count {
            buffer.enqueue(try makePixelBuffer())
        }
    }

    /// The median gap, in seconds, between the drains recorded in `times`
    /// (host-clock nanoseconds).
    private func medianGap(_ times: [UInt64]) -> Double? {
        let gaps = zip(times.dropFirst(), times).map { Double($0 - $1) / 1e9 }.sorted()
        return gaps.isEmpty ? nil : gaps[gaps.count / 2]
    }

    func testItDrainsAtTheDefaultRateUntilTold() {
        let buffer = JitterBuffer { _ in }
        XCTAssertEqual(buffer.drainRate, Tuning.jitterBufferDefaultDrainFPS)
        buffer.setDrainRate(60)
        XCTAssertEqual(buffer.drainRate, 60)
        buffer.setDrainRate(500)
        XCTAssertEqual(buffer.drainRate, Tuning.jitterBufferMaxDrainFPS)
    }

    /// At 60 fps the buffer holds the same ~200 ms before it starts: twice the frames.
    func testAFasterCameraPrimesOnTheSameCushionInTime() throws {
        let buffer = JitterBuffer { _ in }
        buffer.setDrainRate(60)
        let priming = JitterBufferSizing(drainFPS: 60).primingThreshold
        try enqueue(priming - 1, into: buffer)
        XCTAssertFalse(buffer.isDraining)
        try enqueue(1, into: buffer)
        XCTAssertTrue(buffer.isDraining)
        buffer.reset()
    }

    /// A lower rate needs fewer frames: if enough are already held, draining starts.
    func testASlowerRateStartsDrainingWhenEnoughIsHeld() throws {
        let buffer = JitterBuffer { _ in }
        buffer.setDrainRate(60)
        try enqueue(Tuning.jitterBufferPrimingThreshold, into: buffer)
        XCTAssertFalse(buffer.isDraining)
        buffer.setDrainRate(Tuning.jitterBufferDefaultDrainFPS)
        XCTAssertTrue(buffer.isDraining)
        buffer.reset()
    }

    /// The rate survives a reset: a reconnect of the same camera keeps it, and a new
    /// connection gets the default from the dispatcher (`StreamFrameDispatcher.accept`).
    func testTheRateSurvivesAReset() {
        let buffer = JitterBuffer { _ in }
        buffer.setDrainRate(25)
        buffer.reset()
        XCTAssertEqual(buffer.drainRate, 25)
    }

    /// The drain timer runs at the rate set before priming, and is re-armed at a rate
    /// set while it runs.
    func testFramesGoOutAtTheSetRate() throws {
        let times = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        let buffer = JitterBuffer { _ in
            let now = DispatchTime.now().uptimeNanoseconds
            times.withLock { $0.append(now) }
        }

        buffer.setDrainRate(60)
        try enqueue(JitterBufferSizing(drainFPS: 60).primingThreshold, into: buffer)
        Thread.sleep(forTimeInterval: 0.5)
        let atSixty = medianGap(times.withLock { $0 })

        buffer.setDrainRate(Tuning.jitterBufferDefaultDrainFPS)
        times.withLock { $0.removeAll() }
        Thread.sleep(forTimeInterval: 0.5)
        let atThirty = medianGap(times.withLock { $0 })
        buffer.reset()

        XCTAssertEqual(try XCTUnwrap(atSixty), 1.0 / 60, accuracy: 0.004)
        XCTAssertEqual(try XCTUnwrap(atThirty), 1.0 / Tuning.jitterBufferDefaultDrainFPS, accuracy: 0.006)
    }
}
