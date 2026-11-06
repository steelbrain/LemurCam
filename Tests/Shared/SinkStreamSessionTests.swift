@testable import LemurCam
import XCTest

/// Pins the camera extension's sink-stream session bookkeeping. Every consume
/// completion must be checked against the session it was issued under: after a
/// quick stop/start, a completion from the old session used to stop the new one
/// (error branch) or start a second concurrent consume loop (buffer branch),
/// because only the throttled re-arm checked the generation.
internal final class SinkStreamSessionTests: XCTestCase {

    // MARK: - Start / stop

    func testFreshSessionIsIdleAndHasNoCurrentGeneration() {
        let session = SinkStreamSession()
        XCTAssertFalse(session.isStreaming)
        XCTAssertFalse(session.isCurrent(session.generation))
    }

    func testStartReturnsTheLiveGeneration() {
        var session = SinkStreamSession()
        let generation = session.start()
        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(session.generation, generation)
        XCTAssertTrue(session.isCurrent(generation))
    }

    func testStopEndsTheSession() {
        var session = SinkStreamSession()
        let generation = session.start()
        session.stop()
        XCTAssertFalse(session.isStreaming)
        XCTAssertFalse(session.isCurrent(generation))
    }

    func testEveryStartIssuesANewGeneration() {
        var session = SinkStreamSession()
        let first = session.start()
        session.stop()
        let second = session.start()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(session.isCurrent(first))
        XCTAssertTrue(session.isCurrent(second))

        // A restart without an intervening stop also retires the earlier session.
        let third = session.start()
        XCTAssertFalse(session.isCurrent(second))
        XCTAssertTrue(session.isCurrent(third))
    }

    // MARK: - Completion actions

    func testLiveCompletionsFollowTheScheduler() {
        var session = SinkStreamSession()
        let generation = session.start()

        XCTAssertEqual(
            session.completionAction(generation: generation, hasBuffer: true, hasError: false, frameRate: 60),
            .proceed(.resubscribeImmediately)
        )
        XCTAssertEqual(
            session.completionAction(generation: generation, hasBuffer: false, hasError: false, frameRate: 60),
            .proceed(.resubscribeAfter(nanoseconds: 16_666_666))
        )
        XCTAssertEqual(
            session.completionAction(generation: generation, hasBuffer: false, hasError: true, frameRate: 60),
            .proceed(.stop)
        )
    }

    func testCompletionsAfterStopAreDiscarded() {
        var session = SinkStreamSession()
        let generation = session.start()
        session.stop()

        for (hasBuffer, hasError) in [(true, false), (false, false), (false, true), (true, true)] {
            XCTAssertEqual(
                session.completionAction(
                    generation: generation, hasBuffer: hasBuffer, hasError: hasError, frameRate: 60
                ),
                .discardStale,
                "buffer=\(hasBuffer) error=\(hasError)"
            )
        }
    }

    func testOldSessionCompletionsAreDiscardedAfterQuickRestart() {
        var session = SinkStreamSession()
        let old = session.start()
        session.stop()
        let new = session.start()

        // The old loop's buffer must not re-arm a second loop next to the new one.
        XCTAssertEqual(
            session.completionAction(generation: old, hasBuffer: true, hasError: false, frameRate: 60),
            .discardStale
        )
        // The old loop's error must not tear down the new session.
        XCTAssertEqual(
            session.completionAction(generation: old, hasBuffer: false, hasError: true, frameRate: 60),
            .discardStale
        )
        // The new session's own completions still drive it.
        XCTAssertEqual(
            session.completionAction(generation: new, hasBuffer: true, hasError: false, frameRate: 60),
            .proceed(.resubscribeImmediately)
        )
    }

    // MARK: - Disconnect

    func testDisconnectStopsOnlyTheLiveSession() {
        var session = SinkStreamSession()
        let generation = session.start()

        XCTAssertTrue(session.disconnect(ifCurrent: generation))
        XCTAssertFalse(session.isStreaming)
        XCTAssertFalse(session.isCurrent(generation))

        // A second error from the same, now ended, session is a no-op.
        XCTAssertFalse(session.disconnect(ifCurrent: generation))
    }

    func testStaleDisconnectLeavesTheNewSessionRunning() {
        var session = SinkStreamSession()
        let old = session.start()
        session.stop()
        let new = session.start()
        let before = session

        XCTAssertFalse(session.disconnect(ifCurrent: old))
        XCTAssertEqual(session, before, "a stale disconnect must not change the session")
        XCTAssertTrue(session.isCurrent(new))
    }
}
