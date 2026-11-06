@testable import LemurCam
import XCTest

/// Private heap-allocated `LemurAudioRing` fixtures shared by the ring test classes.
/// Never the real shared region a live driver maps, so tests can't perturb an install.
internal enum RingTestSupport {
    static let channels = Int(LEMUR_AUDIO_CHANNELS)
    static let capacity = UInt32(LEMUR_AUDIO_RING_CAPACITY_FRAMES)
    static let canaryBytes = 4096
    static let canaryByte: UInt8 = 0xAB

    /// A zero-filled region followed by a canary tail, so an out-of-bounds slot write
    /// shows up as a clobbered canary (or a crash) instead of silently passing. A
    /// zero-filled region matches a freshly created (uninitialised) shm object.
    /// Caller owns it and must `release` it.
    static func makeRing() -> UnsafeMutablePointer<LemurAudioRing> {
        let size = MemoryLayout<LemurAudioRing>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: size + canaryBytes, alignment: MemoryLayout<LemurAudioRing>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        (raw + size).initializeMemory(as: UInt8.self, repeating: canaryByte, count: canaryBytes)
        return raw.bindMemory(to: LemurAudioRing.self, capacity: 1)
    }

    static func release(_ ring: UnsafeMutablePointer<LemurAudioRing>) {
        UnsafeMutableRawPointer(ring).deallocate()
    }

    static func canaryIntact(_ ring: UnsafeMutablePointer<LemurAudioRing>) -> Bool {
        let tail = UnsafeRawPointer(ring) + MemoryLayout<LemurAudioRing>.size
        return UnsafeRawBufferPointer(start: tail, count: canaryBytes).allSatisfy { $0 == canaryByte }
    }

    /// Fill every slot with a recognisable "stale" value so a replay is detectable.
    /// `samples` is too large for the Clang importer, so its offset is derived from
    /// the field before it (`producing`, an Int32 followed directly by the floats).
    static func fillSlots(_ ring: UnsafeMutablePointer<LemurAudioRing>, with value: Float) {
        guard let producing = MemoryLayout<LemurAudioRing>.offset(of: \LemurAudioRing.producing) else {
            XCTFail("producing offset unavailable")
            return
        }
        let offset = producing + MemoryLayout<Int32>.size
        let count = Int(capacity) * channels
        XCTAssertEqual(offset + count * MemoryLayout<Float>.size, MemoryLayout<LemurAudioRing>.size - 4)
        (UnsafeMutableRawPointer(ring) + offset)
            .bindMemory(to: Float.self, capacity: count)
            .update(repeating: value, count: count)
    }

    @discardableResult
    static func write(_ ring: UnsafeMutablePointer<LemurAudioRing>, _ samples: [Float]) -> UInt32 {
        let frames = UInt32(samples.count / channels)
        return samples.withUnsafeBufferPointer {
            lemur_ring_write(ring, $0.baseAddress, frames, 1)
        }
    }

    /// Write `frames` frames whose left/right samples both equal the frame's
    /// sequence number, starting at `first`.
    @discardableResult
    static func writeSequence(_ ring: UnsafeMutablePointer<LemurAudioRing>, from first: Int, frames: Int) -> UInt32 {
        write(ring, (first..<(first + frames)).flatMap { [Float($0), Float($0)] })
    }

    static func read(
        _ ring: UnsafeMutablePointer<LemurAudioRing>, frames: Int
    ) -> (copied: UInt32, samples: [Float]) {
        var dst = [Float](repeating: .nan, count: frames * channels)
        let copied = dst.withUnsafeMutableBufferPointer {
            lemur_ring_read(ring, $0.baseAddress, UInt32(frames))
        }
        return (copied, dst)
    }
}
