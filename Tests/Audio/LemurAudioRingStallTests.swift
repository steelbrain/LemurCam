@testable import LemurCam
import XCTest

/// Covers the pacer's stall reserve. The backlog a network stall leaves behind is the
/// cushion that absorbs the next stall of the same length; trimming it back to the
/// target every window turned each repeated stall into a gap (underrun) plus a skip.
/// The pacer now keeps a reserve covering the longest recent gap between producer
/// writes and only trims it once no such gap has been seen for a while.
internal final class LemurAudioRingStallTests: XCTestCase {
    private typealias Simulation = RingPacerSimulation
    private let target = Int(LEMUR_AUDIO_RING_TARGET_FRAMES)
    private let window = Int(LEMUR_AUDIO_RING_PACER_WINDOW_FRAMES)
    private let maxReserve = Int(LEMUR_AUDIO_RING_RESERVE_MAX_FRAMES)
    private let memoryWindows = Int(LEMUR_AUDIO_RING_RESERVE_PERIOD_WINDOWS)
    private let second = 48_000

    /// True during a `length`-frame stall in the middle of every `period` frames.
    private func periodicStall(period: Int, length: Int) -> (Int) -> Bool {
        { time in
            let phase = time % period
            return phase >= period / 2 && phase < period / 2 + length
        }
    }

    /// Runs the same stalls paced and unpaced: with the reserve, the pacer must add
    /// no gap and no skip to what playing every frame (no trimming at all) gives.
    private func assertStallsAbsorbed(
        duration: Int, period: Int, length: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let paced = Simulation()
        let unpaced = Simulation(paced: false)
        for sim in [paced, unpaced] {
            sim.produce(960)
            sim.runWithStalls(duration: duration, isStalled: periodicStall(period: period, length: length))
        }
        XCTAssertGreaterThan(unpaced.gaps, 0, "the first stall is always heard", file: file, line: line)
        XCTAssertLessThanOrEqual(unpaced.gaps, 2, "its backlog absorbs the later stalls", file: file, line: line)
        XCTAssertEqual(paced.gaps, unpaced.gaps, file: file, line: line)
        XCTAssertEqual(paced.underrunFrames, unpaced.underrunFrames, file: file, line: line)
        XCTAssertEqual(paced.skips, 0, file: file, line: line)
    }

    func testStallsEveryTenSecondsAreAbsorbed() {
        // 120 ms stalls every 10 s for 2 minutes. Before the reserve each one was a
        // gap plus a skip.
        assertStallsAbsorbed(duration: 120 * second, period: 10 * second, length: 5760)
    }

    func testLongerStallsEveryThreeSecondsAreAbsorbed() {
        assertStallsAbsorbed(duration: 60 * second, period: 3 * second, length: 7200)
    }

    func testStallsEveryHalfMinuteAreAbsorbed() {
        assertStallsAbsorbed(duration: 150 * second, period: 30 * second, length: 5760)
    }

    func testOneOffStallKeepsItsCushionThenSettlesNearTarget() {
        let sim = Simulation()
        sim.produce(960)
        let stallStart = 5 * second
        let stalled: (Int) -> Bool = { $0 >= stallStart && $0 < stallStart + 5760 }
        sim.runWithStalls(duration: 15 * second, isStalled: stalled)

        XCTAssertEqual(sim.gaps, 1)
        XCTAssertEqual(sim.skips, 0, "the cushion is kept while the stall is recent")
        XCTAssertGreaterThan(sim.backlog, 5760 - 1024)

        // After at most two memory periods without another stall, one skip trims it.
        sim.runWithStalls(duration: 2 * memoryWindows * window, isStalled: { _ in false })
        XCTAssertEqual(sim.skips, 1)
        XCTAssertLessThanOrEqual(sim.backlog, target + 960)
        XCTAssertGreaterThanOrEqual(sim.backlog, target - 512)
    }

    func testStallsLongerThanTheCapAreTrimmedToTheCap() {
        let sim = Simulation()
        sim.produce(960)
        // 300 ms stalls: absorbing them would hold 300 ms of latency.
        sim.runWithStalls(duration: 30 * second, isStalled: periodicStall(period: 10 * second, length: 14_400))
        sim.resetMaxBacklog()
        sim.runWithStalls(duration: 2 * window, isStalled: { _ in false })

        XCTAssertLessThanOrEqual(sim.maxBacklog, target + maxReserve + 960)
    }

    func testOutageLongerThanTheRingIsNotLearned() {
        let sim = Simulation()
        sim.produce(1920)
        // The producer stops for 2 s (e.g. the camera reconnects) and then resumes.
        let outageEnd = 3 * second
        sim.run(duration: outageEnd, producing: { $0 < second || $0 >= outageEnd })
        sim.run(duration: 2 * window)
        // A burst with no gap before it: an outage must not have raised the reserve,
        // so the burst is still trimmed within a window or two, not a minute later.
        sim.produce(9600)
        sim.run(duration: 3 * window)

        XCTAssertEqual(sim.pacer.reserve, 0)
        XCTAssertEqual(sim.pacer.previousReserve, 0)
        XCTAssertEqual(sim.skips, 1)
        XCTAssertLessThanOrEqual(sim.backlog, target + 960)
    }

    func testResetForgetsTheReserve() {
        let sim = Simulation()
        sim.produce(960)
        sim.runWithStalls(duration: 10 * second, isStalled: { $0 >= 5 * self.second && $0 < 5 * self.second + 5760 })
        XCTAssertGreaterThan(Int(sim.pacer.reserve), 0)

        lemur_ring_pacer_reset(&sim.pacer)
        XCTAssertEqual(sim.pacer.reserve, 0)
        XCTAssertEqual(sim.pacer.previousReserve, 0)
        XCTAssertEqual(sim.pacer.periodWindows, 0)
    }
}
