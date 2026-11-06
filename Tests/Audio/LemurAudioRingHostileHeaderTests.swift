@testable import LemurCam
import XCTest

/// The ring lives in shared memory the other process maps read-write, so its header
/// and indices can change at any time after `lemur_ring_ready` passed. The helpers
/// must stay inside `samples` and must never replay stale slots, whatever the fields
/// hold. Regression tests for the audit's C2 (field-derived mask) and C8 (inverted
/// indices replaying old audio).
internal final class LemurAudioRingHostileHeaderTests: XCTestCase {
    private typealias Support = RingTestSupport
    private let capacity = RingTestSupport.capacity
    private let channels = RingTestSupport.channels

    func testZeroCapacityFieldCannotSteerAccessOutsideSamples() {
        let ring = Support.makeRing(); defer { Support.release(ring) }
        lemur_ring_init(ring)

        // capacityFrames == 0 used to turn the slot mask into 0xFFFFFFFF; with indices
        // near 2^32 that addressed memory gigabytes past the mapping.
        ring.pointee.capacityFrames = 0
        ring.pointee.channels = 0
        ring.pointee.readIndex = 0xFFFF_FF00
        ring.pointee.writeIndex = 0xFFFF_FF00

        XCTAssertEqual(Support.writeSequence(ring, from: 0, frames: 512), 512)
        let (copied, out) = Support.read(ring, frames: 512)
        XCTAssertEqual(copied, 512)
        XCTAssertEqual(out, (0..<512).flatMap { [Float($0), Float($0)] })
        XCTAssertTrue(Support.canaryIntact(ring), "a ring helper wrote past the region")
    }

    func testHugeCapacityFieldDoesNotInflateFreeSpace() {
        let ring = Support.makeRing(); defer { Support.release(ring) }
        lemur_ring_init(ring)

        ring.pointee.capacityFrames = .max
        XCTAssertEqual(lemur_ring_free(ring), capacity)

        ring.pointee.writeIndex = capacity // exactly full
        XCTAssertEqual(lemur_ring_free(ring), 0)
        XCTAssertEqual(Support.write(ring, [1, 1]), 0, "a full ring accepts nothing, whatever the header claims")
        XCTAssertTrue(Support.canaryIntact(ring))
    }

    func testInvertedIndicesReadAsEmptyAndResetWithoutReplay() {
        let ring = Support.makeRing(); defer { Support.release(ring) }
        lemur_ring_init(ring)
        Support.fillSlots(ring, with: 9)

        // The C8 race: the producer pulled writeIndex back while a read advanced
        // readIndex, leaving W=0 R=512. Raw subtraction reports 4294966784 frames.
        ring.pointee.writeIndex = 0
        ring.pointee.readIndex = 512
        XCTAssertEqual(lemur_ring_filled(ring), 0)
        XCTAssertEqual(lemur_ring_free(ring), capacity)

        let (copied, out) = Support.read(ring, frames: 256)
        XCTAssertEqual(copied, 0, "an inverted ring must not replay stale slots")
        XCTAssertEqual(out, [Float](repeating: 0, count: 256 * channels))
        XCTAssertEqual(ring.pointee.readIndex, 0, "the consumer resets to the write head")
    }

    func testDistanceJustBeyondCapacityResetsWhileExactlyFullStillReads() {
        let ring = Support.makeRing(); defer { Support.release(ring) }
        lemur_ring_init(ring)
        Support.fillSlots(ring, with: 9)

        ring.pointee.readIndex = 100
        ring.pointee.writeIndex = 100 + capacity // exactly full: valid
        XCTAssertEqual(lemur_ring_filled(ring), capacity)
        XCTAssertEqual(Support.read(ring, frames: 4).copied, 4)

        ring.pointee.writeIndex = ring.pointee.readIndex + capacity + 1 // one past: corrupted
        XCTAssertEqual(lemur_ring_filled(ring), 0)
        XCTAssertEqual(Support.read(ring, frames: 4).copied, 0)
        XCTAssertEqual(ring.pointee.readIndex, ring.pointee.writeIndex)
    }

    func testWriteResyncsInvertedRingSoOnlyFreshFramesAreRead() {
        let ring = Support.makeRing(); defer { Support.release(ring) }
        lemur_ring_init(ring)
        Support.fillSlots(ring, with: 9)

        ring.pointee.writeIndex = 0
        ring.pointee.readIndex = 512
        let fresh: [Float] = [1, 1, 2, 2, 3, 3]
        XCTAssertEqual(Support.write(ring, fresh), 3)
        XCTAssertEqual(ring.pointee.writeIndex, 515, "the producer resyncs to the reader before appending")

        let (copied, out) = Support.read(ring, frames: 3)
        XCTAssertEqual(copied, 3)
        XCTAssertEqual(out, fresh)
    }

    func testFilledAndFreeStayWithinCapacityForAnyIndexPair() {
        let ring = Support.makeRing(); defer { Support.release(ring) }
        lemur_ring_init(ring)

        let values: [UInt32] = [0, 1, 511, 512, capacity - 1, capacity, capacity + 1, 0x7FFF_FFFF, .max - 1, .max]
        for writeIndex in values {
            for readIndex in values {
                ring.pointee.writeIndex = writeIndex
                ring.pointee.readIndex = readIndex
                let filled = lemur_ring_filled(ring)
                XCTAssertLessThanOrEqual(filled, capacity, "w=\(writeIndex) r=\(readIndex)")
                XCTAssertEqual(lemur_ring_free(ring), capacity - filled, "w=\(writeIndex) r=\(readIndex)")
            }
        }
    }

    func testReadWithHostileIndicesNeverTouchesMemoryPastTheRing() {
        let ring = Support.makeRing(); defer { Support.release(ring) }
        lemur_ring_init(ring)
        ring.pointee.capacityFrames = 0

        var dst = [Float](repeating: 0, count: 64 * channels)
        for (writeIndex, readIndex) in [(UInt32.max, UInt32(0)), (0x8000_0000, 0x7FFF_FFF0), (capacity, 0)] {
            ring.pointee.writeIndex = writeIndex
            ring.pointee.readIndex = readIndex
            _ = dst.withUnsafeMutableBufferPointer { lemur_ring_read(ring, $0.baseAddress, 64) }
            _ = dst.withUnsafeBufferPointer { lemur_ring_write(ring, $0.baseAddress, 64, 1) }
        }
        XCTAssertTrue(Support.canaryIntact(ring))
    }
}
