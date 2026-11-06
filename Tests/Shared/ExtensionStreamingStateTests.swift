@testable import LemurCam
import XCTest

/// Pins the camera extension's consumer counting and placeholder/sink decisions
/// (`ExtensionDeviceRuntime`). The counter gates whether live frames from the app
/// reach consuming apps, so a consumer that isn't counted gets no video at all.
internal final class ExtensionStreamingStateTests: XCTestCase {

    // MARK: - Consumer counting

    func testFreshStateForwardsNothingAndShowsThePlaceholder() {
        let state = ExtensionStreamingState()
        XCTAssertEqual(state.consumerCount, 0)
        XCTAssertFalse(state.forwardsSinkFrames)
        XCTAssertTrue(state.emitsPlaceholder)
        XCTAssertFalse(state.placeholderTimerRunning)
    }

    func testFirstConsumerStartsThePlaceholderTimerOnce() {
        var state = ExtensionStreamingState()
        XCTAssertTrue(state.consumerStarted(hasPlaceholder: true))
        XCTAssertTrue(state.placeholderTimerRunning)
        XCTAssertTrue(state.forwardsSinkFrames)

        // A second consumer shares the running timer.
        XCTAssertFalse(state.consumerStarted(hasPlaceholder: true))
        XCTAssertEqual(state.consumerCount, 2)
    }

    func testConsumerIsCountedWhenThePlaceholderFailedToRender() {
        // B9: without a placeholder the consumer used to go uncounted, so every live
        // sink frame was dropped. It must be counted; only the timer is skipped.
        var state = ExtensionStreamingState()
        XCTAssertFalse(state.consumerStarted(hasPlaceholder: false))
        XCTAssertEqual(state.consumerCount, 1)
        XCTAssertTrue(state.forwardsSinkFrames)
        XCTAssertFalse(state.placeholderTimerRunning)

        let outcome = state.consumerStopped()
        XCTAssertEqual(outcome, .init(hasConsumers: false, cancelPlaceholderTimer: false))
        XCTAssertFalse(state.forwardsSinkFrames)
    }

    func testOnlyTheLastConsumerStopsTheTimer() {
        var state = ExtensionStreamingState()
        _ = state.consumerStarted(hasPlaceholder: true)
        _ = state.consumerStarted(hasPlaceholder: true)

        XCTAssertEqual(state.consumerStopped(), .init(hasConsumers: true, cancelPlaceholderTimer: false))
        XCTAssertTrue(state.forwardsSinkFrames)
        XCTAssertTrue(state.placeholderTimerRunning)

        XCTAssertEqual(state.consumerStopped(), .init(hasConsumers: false, cancelPlaceholderTimer: true))
        XCTAssertFalse(state.forwardsSinkFrames)
        XCTAssertFalse(state.placeholderTimerRunning)
    }

    func testUnbalancedStopIsHarmless() {
        var state = ExtensionStreamingState()
        XCTAssertEqual(state.consumerStopped(), .init(hasConsumers: false, cancelPlaceholderTimer: false))
        XCTAssertEqual(state.consumerCount, 0)

        // Counting resumes normally afterwards.
        XCTAssertTrue(state.consumerStarted(hasPlaceholder: true))
        XCTAssertEqual(state.consumerCount, 1)
    }

    func testTimerRestartsForTheNextFirstConsumer() {
        var state = ExtensionStreamingState()
        _ = state.consumerStarted(hasPlaceholder: true)
        _ = state.consumerStopped()
        XCTAssertTrue(state.consumerStarted(hasPlaceholder: true), "a new first consumer needs a new timer")
    }

    // MARK: - Sinking

    func testSinkingHidesThePlaceholder() {
        var state = ExtensionStreamingState()
        state.startSinking()
        XCTAssertTrue(state.isSinking)
        XCTAssertFalse(state.emitsPlaceholder)

        XCTAssertTrue(state.stopSinking())
        XCTAssertTrue(state.emitsPlaceholder)
    }

    func testStopSinkingReportsOnlyTheFirstStop() {
        var state = ExtensionStreamingState()
        XCTAssertFalse(state.stopSinking(), "nothing to stop")
        state.startSinking()
        XCTAssertTrue(state.stopSinking())
        XCTAssertFalse(state.stopSinking(), "already stopped")
    }

    func testSinkingDoesNotAffectConsumerCounting() {
        var state = ExtensionStreamingState()
        state.startSinking()
        XCTAssertFalse(state.forwardsSinkFrames, "sink frames need a consumer to go anywhere")
        _ = state.consumerStarted(hasPlaceholder: true)
        XCTAssertTrue(state.forwardsSinkFrames)
    }
}
