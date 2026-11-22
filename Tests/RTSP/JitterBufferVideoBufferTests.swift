import CoreVideo
@testable import LemurCam
import os
import XCTest

/// Pins the Video Buffer setting in the jitter buffer: Off sends each frame on as it
/// comes, with no start-up wait and nothing re-sent; 100 ms waits for half the
/// frames; and a change reaches a running stream without a reset. The fixed 200 ms
/// put the video that far behind a separate microphone (issue #2).
internal final class JitterBufferVideoBufferTests: XCTestCase {
    /// Frames the buffer sent on, by identity, readable from the test thread.
    private final class Deliveries: Sendable {
        private let frames = OSAllocatedUnfairLock<[UInt]>(initialState: [])

        func append(_ frame: CVPixelBuffer) {
            let frameID = identity(frame)
            frames.withLock { $0.append(frameID) }
        }

        var snapshot: [UInt] {
            frames.withLock { $0 }
        }
    }

    private static func identity(_ frame: CVPixelBuffer) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(frame).toOpaque())
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func makeFrames(_ count: Int) throws -> [CVPixelBuffer] {
        try (0..<count).map { _ in try makePixelBuffer() }
    }

    /// Wait up to `seconds` for `condition`, polling.
    private func wait(seconds: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    // MARK: - Off

    /// The first frame goes on without waiting for more, and each later one too, in
    /// order.
    func testOffSendsEachFrameOnAsItComes() throws {
        let deliveries = Deliveries()
        let buffer = JitterBuffer(videoBuffer: .off) { deliveries.append($0) }
        let frames = try makeFrames(3)

        buffer.enqueue(frames[0])
        XCTAssertTrue(buffer.isDraining)
        XCTAssertTrue(wait { deliveries.snapshot.count == 1 })
        buffer.enqueue(frames[1])
        XCTAssertTrue(wait { deliveries.snapshot.count == 2 })
        buffer.enqueue(frames[2])
        XCTAssertTrue(wait { deliveries.snapshot.count == 3 })

        XCTAssertEqual(deliveries.snapshot, frames.map(Self.identity))
        buffer.reset()
    }

    /// With no buffer, nothing is re-sent while the camera sends nothing: the 200 ms
    /// buffer's drain timer sends the last frame again on every tick.
    func testOffDoesNotResendTheLastFrame() throws {
        let deliveries = Deliveries()
        let buffer = JitterBuffer(videoBuffer: .off) { deliveries.append($0) }
        buffer.setDrainRate(60)

        buffer.enqueue(try makePixelBuffer())
        XCTAssertTrue(wait { deliveries.snapshot.count == 1 })
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(deliveries.snapshot.count, 1)
        buffer.reset()
    }

    /// A reset stops the sending until the next frame, as it stops the drain timer.
    func testOffStopsSendingOnAReset() throws {
        let deliveries = Deliveries()
        let buffer = JitterBuffer(videoBuffer: .off) { deliveries.append($0) }

        buffer.enqueue(try makePixelBuffer())
        XCTAssertTrue(wait { deliveries.snapshot.count == 1 })
        buffer.reset()
        XCTAssertFalse(buffer.isDraining)

        let next = try makePixelBuffer()
        buffer.enqueue(next)
        XCTAssertTrue(buffer.isDraining)
        XCTAssertTrue(wait { deliveries.snapshot.count == 2 })
        XCTAssertEqual(deliveries.snapshot.last, Self.identity(next))
        buffer.reset()
    }

    // MARK: - 100 ms

    func testAHundredMillisecondsPrimesOnHalfTheFrames() throws {
        let buffer = JitterBuffer(videoBuffer: .ms100) { _ in }
        let priming = JitterBufferSizing(drainFPS: Tuning.jitterBufferDefaultDrainFPS, videoBuffer: .ms100)
            .primingThreshold
        XCTAssertEqual(priming * 2, Tuning.jitterBufferPrimingThreshold)

        for frame in try makeFrames(priming - 1) { buffer.enqueue(frame) }
        XCTAssertFalse(buffer.isDraining)
        buffer.enqueue(try makePixelBuffer())
        XCTAssertTrue(buffer.isDraining)
        buffer.reset()
    }

    // MARK: - Changes while streaming

    /// Turned off while it drains, the buffer drops what it holds and the next frame
    /// goes on at once. The held frames are older than it, so none goes on after it.
    func testTurningItOffSendsTheNextFrameOnAtOnce() throws {
        let deliveries = Deliveries()
        let buffer = JitterBuffer { deliveries.append($0) }
        let held = try makeFrames(Tuning.jitterBufferPrimingThreshold)
        for frame in held { buffer.enqueue(frame) }
        XCTAssertTrue(buffer.isDraining)

        buffer.setVideoBuffer(.off)
        XCTAssertEqual(buffer.videoBuffer, .off)
        XCTAssertTrue(buffer.isDraining, "a stream that was being sent on still is")
        let next = try makePixelBuffer()
        buffer.enqueue(next)
        XCTAssertTrue(wait { deliveries.snapshot.contains(Self.identity(next)) })
        Thread.sleep(forTimeInterval: 0.2)
        buffer.reset()

        // A drain tick can fire between the enqueues and the change on a busy machine.
        XCTAssertEqual(deliveries.snapshot.last, Self.identity(next), "nothing goes on after the newest frame")
        XCTAssertEqual(deliveries.snapshot.filter { $0 == Self.identity(next) }.count, 1, "and it goes on once")
    }

    /// Turned back on, the buffer holds the new amount again before it sends on.
    func testTurningItOnHoldsFramesAgain() throws {
        let deliveries = Deliveries()
        let buffer = JitterBuffer(videoBuffer: .off) { deliveries.append($0) }
        buffer.enqueue(try makePixelBuffer())
        XCTAssertTrue(wait { deliveries.snapshot.count == 1 })

        buffer.setVideoBuffer(.ms200)
        XCTAssertFalse(buffer.isDraining)
        for frame in try makeFrames(Tuning.jitterBufferPrimingThreshold - 1) { buffer.enqueue(frame) }
        XCTAssertFalse(buffer.isDraining)
        buffer.enqueue(try makePixelBuffer())
        XCTAssertTrue(buffer.isDraining)
        buffer.reset()
    }

    /// Lowered, the buffer keeps the newest frames the new setting holds and drains
    /// them: the two oldest of five go, and it starts at once with three.
    func testLoweringItDropsTheOldestFrames() throws {
        let deliveries = Deliveries()
        let buffer = JitterBuffer { deliveries.append($0) }
        let held = try makeFrames(Tuning.jitterBufferPrimingThreshold - 1)
        for frame in held { buffer.enqueue(frame) }
        XCTAssertFalse(buffer.isDraining)

        buffer.setVideoBuffer(.ms100)
        XCTAssertTrue(buffer.isDraining)
        XCTAssertTrue(wait { !deliveries.snapshot.isEmpty })
        buffer.reset()

        let kept = JitterBufferSizing(drainFPS: Tuning.jitterBufferDefaultDrainFPS, videoBuffer: .ms100)
            .primingThreshold
        XCTAssertEqual(deliveries.snapshot.first, Self.identity(held[held.count - kept]))
    }

    /// Raised while it drains, the buffer stops sending until it holds the new amount.
    func testRaisingItWaitsForTheNewAmount() throws {
        let buffer = JitterBuffer(videoBuffer: .ms100) { _ in }
        let priming = JitterBufferSizing(drainFPS: Tuning.jitterBufferDefaultDrainFPS, videoBuffer: .ms100)
            .primingThreshold
        for frame in try makeFrames(priming) { buffer.enqueue(frame) }
        XCTAssertTrue(buffer.isDraining)

        buffer.setVideoBuffer(.ms200)
        XCTAssertFalse(buffer.isDraining)
        // It held at most `priming` frames, so this many more always fill it.
        for frame in try makeFrames(Tuning.jitterBufferPrimingThreshold) { buffer.enqueue(frame) }
        XCTAssertTrue(buffer.isDraining)
        buffer.reset()
    }

    /// The setting it already has changes nothing: draining goes on.
    func testTheSameSettingKeepsDraining() throws {
        let buffer = JitterBuffer { _ in }
        for frame in try makeFrames(Tuning.jitterBufferPrimingThreshold) { buffer.enqueue(frame) }
        XCTAssertTrue(buffer.isDraining)

        buffer.setVideoBuffer(.defaultValue)
        XCTAssertTrue(buffer.isDraining)
        buffer.reset()
    }

    /// The setting and the drain rate are kept apart: a new rate keeps the setting,
    /// a new setting keeps the rate, and a reset keeps both.
    func testTheSettingOutlivesRateChangesAndResets() {
        let buffer = JitterBuffer(videoBuffer: .ms100) { _ in }
        buffer.setDrainRate(60)
        XCTAssertEqual(buffer.videoBuffer, .ms100)
        buffer.setVideoBuffer(.off)
        XCTAssertEqual(buffer.drainRate, 60)
        buffer.reset()
        XCTAssertEqual(buffer.videoBuffer, .off)
        XCTAssertEqual(buffer.drainRate, 60)
    }
}
