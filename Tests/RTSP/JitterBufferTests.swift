import CoreVideo
import Foundation
@testable import LemurCam
import os
import XCTest

/// Thread-safe collector for frames delivered on the jitter buffer's background
/// drain queue. Reads happen on the test thread after an expectation resolves.
private final class DrainRecorder: Sendable {
    private let frames = OSAllocatedUnfairLock<[UInt]>(initialState: [])

    func append(_ frame: CVPixelBuffer) {
        let identity = frameIdentity(frame)
        frames.withLock {
            $0.append(identity)
        }
    }

    var count: Int {
        frames.withLock { $0.count }
    }

    func snapshot() -> [UInt] {
        frames.withLock { $0 }
    }
}

private final class DrainSignal: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait(seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + .milliseconds(Int(seconds * 1000))) == .success
    }
}

/// Lock-guarded mutable cell so a test can swap which signal the (fixed,
/// background) drain closure currently fulfills, across drain phases.
private final class Box<Value>: Sendable where Value: Sendable {
    private let value: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        self.value = OSAllocatedUnfairLock(initialState: value)
    }

    var current: Value {
        value.withLock { $0 }
    }

    func set(_ newValue: Value) {
        value.withLock {
            $0 = newValue
        }
    }
}

private func frameIdentity(_ frame: CVPixelBuffer) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(frame).toOpaque())
}

/// Locks the behavior of the jitter buffer that smooths bursty IP-camera delivery:
/// priming, fixed-rate draining, FIFO ordering, capacity eviction, last-frame
/// hold, and reset. Assertions are written against `Tuning` constants (not hard
/// numbers) so they describe behavior rather than the current tuning, and use
/// settle windows so they stay green regardless of scheduler jitter.
internal final class JitterBufferTests: XCTestCase {

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    /// Below the priming threshold the drain timer never starts, so no frame is
    /// ever delivered — the buffer is still accumulating the initial burst.
    func testDoesNotDrainBelowPrimingThreshold() throws {
        let didDrain = DrainSignal()
        let buffer = JitterBuffer { _ in didDrain.signal() }

        for _ in 0..<(Tuning.jitterBufferPrimingThreshold - 1) {
            buffer.enqueue(try makePixelBuffer())
        }

        XCTAssertFalse(didDrain.wait(seconds: 0.5))
        buffer.reset()
    }

    /// Reaching the priming threshold starts the drain timer and frames begin
    /// flowing to the consumer.
    func testStartsDrainingOncePrimed() throws {
        let didDrain = DrainSignal()
        let buffer = JitterBuffer { _ in didDrain.signal() }

        for _ in 0..<Tuning.jitterBufferPrimingThreshold {
            buffer.enqueue(try makePixelBuffer())
        }

        XCTAssertTrue(didDrain.wait(seconds: 2.0))
        buffer.reset()
    }

    /// Frames drain in FIFO order, and once the buffer empties the most recent
    /// frame is re-delivered (held) rather than dropping to nothing.
    func testFIFOOrderThenHoldsLastFrame() throws {
        let threshold = Tuning.jitterBufferPrimingThreshold
        let toObserve = threshold + 2
        let recorder = DrainRecorder()
        let drained = DrainSignal()
        let buffer = JitterBuffer { frame in
            recorder.append(frame)
            if recorder.count >= toObserve { drained.signal() }
        }

        let enqueued = try (0..<threshold).map { _ in try makePixelBuffer() }
        for frame in enqueued { buffer.enqueue(frame) }

        XCTAssertTrue(drained.wait(seconds: 3.0))
        buffer.reset()

        let delivered = recorder.snapshot()
        XCTAssertGreaterThanOrEqual(delivered.count, toObserve)
        // First `threshold` deliveries replay the enqueued burst in order.
        for index in 0..<threshold {
            XCTAssertEqual(delivered[index], frameIdentity(enqueued[index]), "FIFO break at \(index)")
        }
        // After the burst drains, the last enqueued frame is held and re-sent.
        guard let last = enqueued.last else { XCTFail("no frames enqueued"); return }
        for index in threshold..<toObserve {
            XCTAssertEqual(delivered[index], frameIdentity(last), "expected held last frame at \(index)")
        }
    }

    /// When more than `jitterBufferCapacity` frames arrive in a burst before the
    /// drain timer first fires, the oldest are evicted, so the first delivered
    /// frame is the oldest *retained* one — not the oldest enqueued.
    func testCapacityEvictsOldestFrames() throws {
        let capacity = Tuning.jitterBufferCapacity
        let total = capacity + 4
        let firstDelivered = DrainSignal()
        let recorder = DrainRecorder()
        let buffer = JitterBuffer { frame in
            recorder.append(frame)
            firstDelivered.signal()
        }

        // Synchronous burst: all enqueues complete in microseconds, well before the
        // first timer fire (~1/drainFPS seconds), so eviction runs to completion first.
        let enqueued = try (0..<total).map { _ in try makePixelBuffer() }
        for frame in enqueued { buffer.enqueue(frame) }

        XCTAssertTrue(firstDelivered.wait(seconds: 2.0))
        buffer.reset()

        let delivered = recorder.snapshot()
        guard let first = delivered.first else { XCTFail("nothing drained"); return }
        // Retained window is the last `capacity` frames; oldest retained = total-capacity.
        XCTAssertEqual(
            first,
            frameIdentity(enqueued[total - capacity]),
            "eviction did not drop the oldest frames"
        )
    }

    /// After reset the drain timer is cancelled and the buffer is cleared, so
    /// delivery stops. Sample the delivery count across a settle window to confirm
    /// it has gone quiet (tolerating at most one in-flight drain at reset time).
    func testResetStopsDraining() throws {
        let recorder = DrainRecorder()
        let buffer = JitterBuffer { frame in recorder.append(frame) }

        for _ in 0..<Tuning.jitterBufferPrimingThreshold {
            buffer.enqueue(try makePixelBuffer())
        }

        // Let it drain a few frames, then stop it.
        Thread.sleep(forTimeInterval: 0.3)
        buffer.reset()

        // Settle past any drain that was already in flight when reset cancelled the timer.
        Thread.sleep(forTimeInterval: 0.2)
        let countAfterSettle = recorder.count
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(recorder.count, countAfterSettle, "draining continued after reset")
    }

    /// Reset is safe to call when nothing was ever enqueued (no timer to cancel).
    func testResetBeforeAnyEnqueueIsSafe() {
        let buffer = JitterBuffer { _ in
            XCTFail("Reset before enqueue should not deliver frames")
        }
        buffer.reset()
    }

    /// `reset()` (main actor) and `enqueue()` (decode thread) both mutate the
    /// `drainTimer`. Before the fix that field was read/written outside the lock, so
    /// hammering the two concurrently raced the timer's ARC retain/release (a crash
    /// under TSan / over-release) and could leave a timer running after a final reset.
    /// This drives both paths from competing threads across many rounds — re-priming
    /// after each reset re-arms the timer, maximizing the overlap — then asserts the
    /// buffer goes quiet once enqueues stop and a final reset lands.
    func testConcurrentResetAndEnqueueIsRaceFree() throws {
        let recorder = DrainRecorder()
        let buffer = JitterBuffer { frame in recorder.append(frame) }
        let rounds = 200
        let primingThreshold = Tuning.jitterBufferPrimingThreshold
        let frame = SendablePixelBuffer(try makePixelBuffer())

        let group = DispatchGroup()
        let enqueuer = DispatchQueue(label: "test.enqueue")
        let resetter = DispatchQueue(label: "test.reset")

        enqueuer.async(group: group) {
            for _ in 0..<rounds {
                // Each burst re-primes (after a reset cleared isPrimed), re-arming the timer.
                for _ in 0..<primingThreshold {
                    frame.withValue { buffer.enqueue($0) }
                }
            }
        }
        resetter.async(group: group) {
            for _ in 0..<rounds { buffer.reset() }
        }

        let finished = group.wait(timeout: .now() + 10)
        XCTAssertEqual(finished, .success, "concurrent enqueue/reset deadlocked or hung")

        // After both threads stop and a final reset lands, draining must cease.
        buffer.reset()
        Thread.sleep(forTimeInterval: 0.2)
        let countAfterSettle = recorder.count
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(recorder.count, countAfterSettle, "draining continued after final reset")
    }

    /// Reset clears the primed flag, so a later burst re-primes and draining
    /// restarts — reset pauses the buffer, it doesn't permanently disable it.
    func testReprimesAfterReset() throws {
        let active = Box<DrainSignal?>(nil)
        let buffer = JitterBuffer { _ in active.current?.signal() }

        let firstRound = DrainSignal()
        active.set(firstRound)
        for _ in 0..<Tuning.jitterBufferPrimingThreshold {
            buffer.enqueue(try makePixelBuffer())
        }
        XCTAssertTrue(firstRound.wait(seconds: 2.0))

        buffer.reset()
        // Drop any round-one straggler drain so it can't satisfy round two.
        active.set(nil)
        Thread.sleep(forTimeInterval: 0.2)

        let secondRound = DrainSignal()
        active.set(secondRound)
        for _ in 0..<Tuning.jitterBufferPrimingThreshold {
            buffer.enqueue(try makePixelBuffer())
        }
        XCTAssertTrue(secondRound.wait(seconds: 2.0))
        buffer.reset()
    }
}
