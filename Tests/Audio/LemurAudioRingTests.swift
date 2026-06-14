@testable import LemurCam
import XCTest

/// Locks the lock-free SPSC ring contract shared between the app (producer) and
/// the AudioServerPlugIn inside `coreaudiod` (consumer) — see `LemurAudioShared.h`.
/// The index math (power-of-two slot masking, free-running 32-bit counters that
/// wrap, tail-drop on overflow, underrun zero-fill) is the load-bearing part: a
/// regression here silently corrupts the virtual microphone audio. Every test
/// runs against a private heap-allocated `LemurAudioRing`, never the real shared
/// region a live driver maps, so it can't perturb a running install.
internal final class LemurAudioRingTests: XCTestCase {

    private let channels = Int(LEMUR_AUDIO_CHANNELS)
    private let capacity = UInt32(LEMUR_AUDIO_RING_CAPACITY_FRAMES)

    // MARK: - Fixtures

    /// A zero-filled region, matching a freshly created (and thus uninitialised)
    /// POSIX shm object. Caller owns it and must `release` it.
    private func makeZeroedRing() -> UnsafeMutablePointer<LemurAudioRing> {
        let size = MemoryLayout<LemurAudioRing>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<LemurAudioRing>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        return raw.bindMemory(to: LemurAudioRing.self, capacity: 1)
    }

    private func release(_ ring: UnsafeMutablePointer<LemurAudioRing>) {
        UnsafeMutableRawPointer(ring).deallocate()
    }

    @discardableResult
    private func write(
        _ ring: UnsafeMutablePointer<LemurAudioRing>, _ samples: [Float], hostTime: UInt64 = 1
    ) -> UInt32 {
        let frames = UInt32(samples.count / channels)
        return samples.withUnsafeBufferPointer {
            lemur_ring_write(ring, $0.baseAddress, frames, hostTime)
        }
    }

    private func read(
        _ ring: UnsafeMutablePointer<LemurAudioRing>, frames: Int
    ) -> (copied: UInt32, samples: [Float]) {
        var dst = [Float](repeating: .nan, count: frames * channels)
        let copied = dst.withUnsafeMutableBufferPointer {
            lemur_ring_read(ring, $0.baseAddress, UInt32(frames))
        }
        return (copied, dst)
    }

    // MARK: - init / ready

    func testInitEstablishesEmptyReadyRing() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        XCTAssertNotEqual(lemur_ring_ready(ring), 0)
        XCTAssertEqual(ring.pointee.writeIndex, 0)
        XCTAssertEqual(ring.pointee.readIndex, 0)
        XCTAssertEqual(ring.pointee.producing, 0)
        XCTAssertEqual(ring.pointee.lastWriteHostTime, 0)
        XCTAssertEqual(ring.pointee.capacityFrames, capacity)
        XCTAssertEqual(ring.pointee.channels, UInt32(LEMUR_AUDIO_CHANNELS))
        XCTAssertEqual(lemur_ring_filled(ring), 0)
        XCTAssertEqual(lemur_ring_free(ring), capacity)
    }

    func testReadyIsFalseOnZeroedRegion() {
        let ring = makeZeroedRing(); defer { release(ring) }
        // A freshly created shm object is zero-filled (magic == 0), so a consumer
        // mapping it before the producer initialises must see "not ready".
        XCTAssertEqual(lemur_ring_ready(ring), 0)
    }

    func testReadyRejectsWrongMagic() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        ring.pointee.magic = 0xDEAD_BEEF
        XCTAssertEqual(lemur_ring_ready(ring), 0)
    }

    func testReadyRejectsLayoutMismatch() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        // A region written by a different build (capacity or channel count drift)
        // must be rejected so the consumer never reads a mismatched layout.
        ring.pointee.capacityFrames = capacity + 1
        XCTAssertEqual(lemur_ring_ready(ring), 0)
        ring.pointee.capacityFrames = capacity
        XCTAssertNotEqual(lemur_ring_ready(ring), 0)

        ring.pointee.channels = 1
        XCTAssertEqual(lemur_ring_ready(ring), 0)
    }

    // MARK: - write / read round trips

    func testWriteThenReadRoundTripsFramesInOrder() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        let input: [Float] = [0.25, -0.25, 0.5, -0.5, 0.75, -0.75] // 3 stereo frames
        XCTAssertEqual(write(ring, input, hostTime: 0x1234), 3)
        XCTAssertEqual(lemur_ring_filled(ring), 3)
        XCTAssertEqual(lemur_ring_free(ring), capacity - 3)
        XCTAssertEqual(ring.pointee.lastWriteHostTime, 0x1234) // host time published with the batch

        let (copied, out) = read(ring, frames: 3)
        XCTAssertEqual(copied, 3)
        XCTAssertEqual(out, input)
        XCTAssertEqual(lemur_ring_filled(ring), 0)
        XCTAssertEqual(ring.pointee.readIndex, 3)
    }

    func testReadZeroFillsUnderrunAndReturnsAvailable() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        write(ring, [1, 1, 2, 2]) // 2 frames available
        let (copied, out) = read(ring, frames: 5) // ask for more than exists

        XCTAssertEqual(copied, 2)
        XCTAssertEqual(Array(out.prefix(4)), [1, 1, 2, 2])
        XCTAssertEqual(Array(out.suffix(6)), [Float](repeating: 0, count: 6)) // shortfall is silence
        XCTAssertEqual(ring.pointee.readIndex, 2) // advanced only by frames actually present
    }

    func testReadEmptyRingReturnsZeroAndAllSilence() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        let (copied, out) = read(ring, frames: 4)
        XCTAssertEqual(copied, 0)
        XCTAssertEqual(out, [Float](repeating: 0, count: 4 * channels))
        XCTAssertEqual(ring.pointee.readIndex, 0)
    }

    func testWriteZeroFramesIsNoOp() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        XCTAssertEqual(write(ring, []), 0)
        XCTAssertEqual(ring.pointee.writeIndex, 0)
        XCTAssertEqual(lemur_ring_filled(ring), 0)
    }

    // MARK: - overflow / wraparound

    func testWriteDropsTailWhenRingIsFull() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        // Position the ring so only 3 frames are free.
        ring.pointee.readIndex = 5
        ring.pointee.writeIndex = 5 + (capacity - 3)
        XCTAssertEqual(lemur_ring_free(ring), 3)

        // Offer 10 frames (values 0...9); the writer keeps the leading 3 and drops the tail.
        let input = (0..<10).flatMap { [Float($0), Float($0)] }
        XCTAssertEqual(write(ring, input), 3)
        XCTAssertEqual(lemur_ring_free(ring), 0)
        XCTAssertEqual(lemur_ring_filled(ring), capacity)

        // The 3 retained frames are the first three offered (0, 1, 2), in order.
        ring.pointee.readIndex = ring.pointee.writeIndex - 3
        let (copied, out) = read(ring, frames: 3)
        XCTAssertEqual(copied, 3)
        XCTAssertEqual(out, [0, 0, 1, 1, 2, 2])
    }

    func testFramesWrapAroundCapacityBoundaryInOrder() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        // Start two frames short of the capacity boundary so the batch straddles it.
        ring.pointee.readIndex = capacity - 2
        ring.pointee.writeIndex = capacity - 2

        let input: [Float] = [1, 1, 2, 2, 3, 3, 4, 4] // 4 frames cross the slot wrap
        XCTAssertEqual(write(ring, input), 4)

        let (copied, out) = read(ring, frames: 4)
        XCTAssertEqual(copied, 4)
        XCTAssertEqual(out, input) // FIFO order preserved across the masked slot wrap
    }

    func testCountersWrapAtUInt32Boundary() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        // Free-running indices wrap at 2^32; unsigned subtraction must stay correct.
        ring.pointee.readIndex = .max - 1 // 0xFFFFFFFE
        ring.pointee.writeIndex = .max - 1
        XCTAssertEqual(lemur_ring_filled(ring), 0)

        let input: [Float] = [10, 10, 20, 20, 30, 30, 40, 40] // 4 frames straddle 2^32
        XCTAssertEqual(write(ring, input), 4)
        XCTAssertEqual(ring.pointee.writeIndex, 2) // 0xFFFFFFFE + 4 wrapped to 2
        XCTAssertEqual(lemur_ring_filled(ring), 4)

        let (copied, out) = read(ring, frames: 4)
        XCTAssertEqual(copied, 4)
        XCTAssertEqual(out, input)
        XCTAssertEqual(lemur_ring_filled(ring), 0)
    }

    // MARK: - reset

    func testResetReadDrainsToEmpty() {
        let ring = makeZeroedRing(); defer { release(ring) }
        lemur_ring_init(ring)

        write(ring, [1, 1, 2, 2, 3, 3]) // 3 frames queued
        XCTAssertEqual(lemur_ring_filled(ring), 3)

        lemur_ring_reset_read(ring) // consumer drops stale backlog on (re)start
        XCTAssertEqual(lemur_ring_filled(ring), 0)
        XCTAssertEqual(ring.pointee.readIndex, ring.pointee.writeIndex)

        let (copied, _) = read(ring, frames: 2)
        XCTAssertEqual(copied, 0)
    }
}
