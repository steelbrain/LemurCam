@testable import LemurCam
import XCTest

/// Locks the jitter buffer's catch-up decision. The buffer drains at a fixed rate and
/// used to never skip ahead, so a burst left it deep for good (up to the capacity of
/// latency). The tracker drops the frames a whole window of drain ticks showed were
/// never needed: those above the target depth when the depth never fell to it. A
/// window that drained to the target (a keyframe stall used the cushion) drops none.
internal final class JitterDepthTrackerTests: XCTestCase {

    private func record(_ depths: [Int], into tracker: inout JitterDepthTracker) -> [Int] {
        depths.map { tracker.recordDrain(depth: $0) }
    }

    func testDropsTheExcessOfAWindowThatStayedAboveTheTarget() {
        var tracker = JitterDepthTracker(windowTicks: 4, targetDepth: 6)

        let drops = record([14, 13, 12, 12], into: &tracker)

        XCTAssertEqual(drops, [0, 0, 0, 6], "drop down to the target at the end of the window only")
    }

    func testKeepsTheCushionWhenAStallDrainedItWithinTheWindow() {
        var tracker = JitterDepthTracker(windowTicks: 4, targetDepth: 6)

        let drops = record([12, 0, 12, 12], into: &tracker)

        XCTAssertEqual(drops, [0, 0, 0, 0], "a window that underran needed every frame")
    }

    func testDepthAtTheTargetDropsNothing() {
        var tracker = JitterDepthTracker(windowTicks: 3, targetDepth: 6)

        XCTAssertEqual(record([6, 7, 8], into: &tracker), [0, 0, 0])
    }

    func testEachWindowIsJudgedOnItsOwn() {
        var tracker = JitterDepthTracker(windowTicks: 2, targetDepth: 6)

        XCTAssertEqual(record([0, 10], into: &tracker), [0, 0], "the first window underran")
        XCTAssertEqual(record([10, 9], into: &tracker), [0, 3], "the next window starts fresh")
    }

    func testResetStartsANewWindow() {
        var tracker = JitterDepthTracker(windowTicks: 3, targetDepth: 6)
        XCTAssertEqual(record([0, 10], into: &tracker), [0, 0])

        tracker.reset()

        XCTAssertEqual(record([10, 10, 10], into: &tracker), [0, 0, 4], "the low depth before reset is forgotten")
    }

    func testWindowIsAtLeastOneTick() {
        var tracker = JitterDepthTracker(windowTicks: 0, targetDepth: 6)

        XCTAssertEqual(tracker.recordDrain(depth: 8), 2)
    }
}
