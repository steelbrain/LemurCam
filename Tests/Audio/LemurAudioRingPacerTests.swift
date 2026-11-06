@testable import LemurCam
import XCTest

/// Covers the consumer-side latency policy (`lemur_ring_read_paced`): backlog that
/// persists for a whole window is trimmed to the target, a full ring drops its oldest
/// audio, and ordinary jitter or large producer packets are left alone. Without it the
/// backlog after any burst or underrun stayed as permanent latency (up to ~341 ms).
internal final class LemurAudioRingPacerTests: XCTestCase {
    private typealias Support = RingTestSupport
    private let target = Int(LEMUR_AUDIO_RING_TARGET_FRAMES)
    private let highWater = Int(LEMUR_AUDIO_RING_HIGH_WATER_FRAMES)
    private let window = Int(LEMUR_AUDIO_RING_PACER_WINDOW_FRAMES)
    private let capacity = Int(RingTestSupport.capacity)

    /// Producer/consumer simulation in frame time. Frames carry consecutive sequence
    /// numbers (from 1, so 0 means underrun silence); the consumer counts every jump
    /// in the sequence it plays, which is exactly a trim.
    private final class Simulation {
        let ring = Support.makeRing()
        var pacer = LemurAudioRingPacer()
        private(set) var nextSequence = 1
        private(set) var lastPlayed = 0
        private(set) var skips = 0
        private(set) var underrunFrames = 0

        init() {
            lemur_ring_init(ring)
            lemur_ring_pacer_reset(&pacer)
        }

        deinit { Support.release(ring) }

        var backlog: Int { Int(lemur_ring_filled(ring)) }

        func produce(_ frames: Int) {
            Support.writeSequence(ring, from: nextSequence, frames: frames)
            nextSequence += frames
        }

        func consume(_ frames: Int) {
            var dst = [Float](repeating: .nan, count: frames * Support.channels)
            let copied = dst.withUnsafeMutableBufferPointer {
                lemur_ring_read_paced(ring, &pacer, $0.baseAddress, UInt32(frames))
            }
            underrunFrames += frames - Int(copied)
            for frame in 0..<Int(copied) {
                let played = Int(dst[frame * Support.channels])
                if lastPlayed != 0, played != lastPlayed + 1 { skips += 1 }
                lastPlayed = played
            }
        }

        /// Run `duration` frames of real time: the consumer reads `readChunk` frames
        /// per IO cycle; the producer delivers `producerChunk` frames whenever a whole
        /// chunk of real time has elapsed (unless `producing` says otherwise).
        func run(
            duration: Int, readChunk: Int = 512, producerChunk: Int = 960,
            producing: (Int) -> Bool = { _ in true }
        ) {
            var produced = 0
            var time = 0
            while time < duration {
                time += readChunk
                while produced + producerChunk <= time {
                    produced += producerChunk
                    if producing(produced) { produce(producerChunk) }
                }
                consume(readChunk)
            }
        }
    }

    func testSteadyStreamWithSmallBacklogIsNeverTrimmed() {
        let sim = Simulation()
        sim.produce(1920) // 40 ms head start, under the high-water mark
        sim.run(duration: 5 * window)

        XCTAssertEqual(sim.skips, 0)
        XCTAssertEqual(sim.underrunFrames, 0)
        XCTAssertLessThanOrEqual(sim.backlog, highWater)
    }

    func testSustainedBacklogIsTrimmedOnceToTheTarget() {
        let sim = Simulation()
        sim.produce(9600) // 200 ms of backlog, e.g. a burst after a network stall
        sim.run(duration: 3 * window)

        XCTAssertEqual(sim.skips, 1, "one trim, not a click every window")
        XCTAssertEqual(sim.underrunFrames, 0, "trimming must never starve the reader")
        // Backlog left after a read now sits at the target plus at most one producer packet.
        XCTAssertLessThanOrEqual(sim.backlog, target + 960)
        XCTAssertGreaterThanOrEqual(sim.backlog, target - 512)
    }

    func testLargeProducerPacketsWithLowFloorAreNotMistakenForBacklog() {
        let sim = Simulation()
        // 128 ms packets (e.g. 1024-sample G.711 at 8 kHz, resampled): the ring swings
        // by 6144 frames per packet, but the floor before each packet stays low.
        sim.produce(1024)
        sim.run(duration: 5 * window, producerChunk: 6144)

        XCTAssertEqual(sim.skips, 0)
    }

    func testUnderrunFollowedByLateBurstSettlesBackNearTarget() {
        let sim = Simulation()
        sim.produce(1920)
        // The camera stalls for 300 ms, then the queued packets all arrive at once:
        // without trimming, that 300 ms would ride on every later frame.
        let stallEnd = window
        sim.run(duration: stallEnd, producing: { $0 < stallEnd - 14_400 })
        sim.produce(14_400)
        sim.run(duration: 3 * window)

        XCTAssertGreaterThan(sim.underrunFrames, 0, "the stall itself is heard as silence")
        XCTAssertEqual(sim.skips, 1)
        XCTAssertLessThanOrEqual(sim.backlog, target + 960)
    }

    func testFullRingDropsTheOldestAudioImmediately() {
        let sim = Simulation()
        sim.produce(capacity + 1000) // the producer drops the 1000 newest frames
        XCTAssertEqual(sim.backlog, capacity)

        sim.consume(512)
        // Kept: the newest target + 512 frames; this read plays the oldest 512 of those.
        XCTAssertEqual(sim.lastPlayed, capacity - target)
        XCTAssertEqual(sim.backlog, target)
    }

    func testOutOfRangeIndicesResetThePacerWindow() {
        let sim = Simulation()
        sim.produce(9600)
        sim.consume(512) // starts a window with a large floor
        sim.ring.pointee.readIndex = sim.ring.pointee.writeIndex &+ 1 // inverted
        sim.consume(512)

        XCTAssertEqual(sim.pacer.windowFrames, 0)
        XCTAssertEqual(sim.pacer.minBacklog, .max)
        XCTAssertEqual(sim.backlog, 0)
    }

    func testUnpacedReadPlaysEveryBufferedFrame() {
        let sim = Simulation()
        sim.produce(9600)
        for _ in 0..<(3 * window / 512) {
            _ = Support.read(sim.ring, frames: 512)
            sim.produce(512)
        }
        XCTAssertEqual(sim.backlog, 9600, "lemur_ring_read keeps its old play-everything behaviour")
    }
}
