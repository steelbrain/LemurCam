// This import brings in the app's bridging header (the C ring API), a use the analyzer misses.
// swiftlint:disable:next unused_import
@testable import LemurCam
import XCTest

/// Covers the consumer-side latency policy (`lemur_ring_read_paced`): backlog that
/// persists for a whole window is trimmed to the target, a full ring drops its oldest
/// audio, and ordinary jitter or large producer packets are left alone. Without it the
/// backlog after any burst or underrun stayed as permanent latency (up to ~341 ms).
/// How stalls set the reserve is covered by `LemurAudioRingStallTests`.
internal final class LemurAudioRingPacerTests: XCTestCase {
    private typealias Support = RingTestSupport
    private let target = Int(LEMUR_AUDIO_RING_TARGET_FRAMES)
    private let highWater = Int(LEMUR_AUDIO_RING_HIGH_WATER_FRAMES)
    private let window = Int(LEMUR_AUDIO_RING_PACER_WINDOW_FRAMES)
    private let capacity = Int(RingTestSupport.capacity)
    private let maxReserve = Int(LEMUR_AUDIO_RING_RESERVE_MAX_FRAMES)
    private let memoryWindows = Int(LEMUR_AUDIO_RING_RESERVE_PERIOD_WINDOWS)

    private typealias Simulation = RingPacerSimulation

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

    func testUnderrunFollowedByLateBurstKeepsACushionThenSettlesNearTarget() {
        let sim = Simulation()
        sim.produce(1920)
        // The camera stalls for 300 ms, then the queued packets all arrive at once.
        let stallEnd = window
        sim.run(duration: stallEnd, producing: { $0 < stallEnd - 14_400 })
        sim.produce(14_400)
        sim.run(duration: 3 * window)

        XCTAssertGreaterThan(sim.underrunFrames, 0, "the stall itself is heard as silence")
        // The backlog the stall left is the cushion for the next one, so it is kept,
        // but only up to the 200 ms cap.
        XCTAssertEqual(sim.skips, 1)
        XCTAssertGreaterThanOrEqual(sim.backlog, target + maxReserve - 512)
        XCTAssertLessThanOrEqual(sim.backlog, target + maxReserve + 960)

        // Once no stall has been seen for a full memory period or two, the cushion
        // goes in one more skip and the latency is back near the target.
        sim.run(duration: 2 * memoryWindows * window)
        XCTAssertEqual(sim.skips, 2)
        XCTAssertLessThanOrEqual(sim.backlog, target + 960)
        XCTAssertGreaterThanOrEqual(sim.backlog, target - 512)
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
        XCTAssertEqual(sim.pacer.reserve, 0)
        XCTAssertEqual(sim.pacer.previousReserve, 0)
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
