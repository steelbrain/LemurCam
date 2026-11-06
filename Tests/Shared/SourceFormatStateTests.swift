@testable import LemurCam
import XCTest

/// Pins when the user's default format reaches the camera other apps capture
/// from. The app sets it through the sink stream; the extension applies it while
/// no app uses the camera, and holds it while one does, so the app never changes
/// the format under a running app. An app's own choice applies at once.
internal final class SourceFormatStateTests: XCTestCase {
    private let start = StreamFormatSelection(resolution: .hd1080, frameRate: .fps60)

    // MARK: - The default, while idle

    func testADefaultSetWhileIdleAppliesAtOnce() {
        var state = SourceFormatState(initial: start)

        let applied = state.defaultSet(resolution: .hd720, frameRate: .fps30, sourceHasConsumers: false)

        let expected = StreamFormatSelection(resolution: .hd720, frameRate: .fps30)
        XCTAssertEqual(applied, expected)
        XCTAssertEqual(state.active, expected)
        XCTAssertEqual(state.preferred, expected)
        XCTAssertNil(state.pending)
    }

    /// The app sets the format and the frame rate as two properties, so they
    /// arrive in two calls; each one applies.
    func testFormatAndRateSetSeparatelyBothApply() {
        var state = SourceFormatState(initial: start)

        XCTAssertEqual(
            state.defaultSet(resolution: .uhd4k, frameRate: nil, sourceHasConsumers: false),
            StreamFormatSelection(resolution: .uhd4k, frameRate: .fps60)
        )
        XCTAssertEqual(
            state.defaultSet(resolution: nil, frameRate: .fps30, sourceHasConsumers: false),
            StreamFormatSelection(resolution: .uhd4k, frameRate: .fps30)
        )
        XCTAssertEqual(state.active, StreamFormatSelection(resolution: .uhd4k, frameRate: .fps30))
    }

    /// The app sets its setting at every discovery; an unchanged one announces nothing.
    func testADefaultThatIsAlreadyActiveAnnouncesNothing() {
        var state = SourceFormatState(initial: start)

        XCTAssertNil(state.defaultSet(resolution: .hd1080, frameRate: .fps60, sourceHasConsumers: false))
        XCTAssertEqual(state.active, start)
    }

    /// A launch of the app sets its setting again; while idle it replaces a format
    /// an earlier app chose.
    func testADefaultSetWhileIdleReplacesAnEarlierAppsChoice() {
        var state = SourceFormatState(initial: start)
        state.sourceClientSet(resolution: .uhd4k, frameRate: .fps30)

        let applied = state.defaultSet(resolution: .hd1080, frameRate: .fps60, sourceHasConsumers: false)

        XCTAssertEqual(applied, start)
        XCTAssertEqual(state.active, start)
    }

    // MARK: - The default, while in use

    func testADefaultSetWhileInUseWaitsForTheLastConsumer() {
        var state = SourceFormatState(initial: start)

        XCTAssertNil(state.defaultSet(resolution: .hd720, frameRate: .fps30, sourceHasConsumers: true))

        let expected = StreamFormatSelection(resolution: .hd720, frameRate: .fps30)
        XCTAssertEqual(state.active, start, "the running app keeps its format")
        XCTAssertEqual(state.preferred, expected, "the sink reports what the app set")
        XCTAssertEqual(state.pending, expected)

        XCTAssertEqual(state.sourceBecameIdle(), expected)
        XCTAssertEqual(state.active, expected)
        XCTAssertNil(state.pending)
    }

    func testTheLatestDefaultSetWhileInUseIsTheOneApplied() {
        var state = SourceFormatState(initial: start)
        _ = state.defaultSet(resolution: .hd720, frameRate: nil, sourceHasConsumers: true)
        _ = state.defaultSet(resolution: .qhd1440, frameRate: nil, sourceHasConsumers: true)
        _ = state.defaultSet(resolution: nil, frameRate: .fps30, sourceHasConsumers: true)

        XCTAssertEqual(state.sourceBecameIdle(), StreamFormatSelection(resolution: .qhd1440, frameRate: .fps30))
    }

    /// The default was set while an app ran; that app (or another) then chose a
    /// format of its own. The waiting default still applies once none is left.
    func testAWaitingDefaultOutlastsAnAppsLaterChoice() {
        var state = SourceFormatState(initial: start)
        _ = state.defaultSet(resolution: .hd720, frameRate: .fps30, sourceHasConsumers: true)
        state.sourceClientSet(resolution: .uhd4k, frameRate: nil)
        XCTAssertEqual(state.active.resolution, .uhd4k)

        XCTAssertEqual(state.sourceBecameIdle(), StreamFormatSelection(resolution: .hd720, frameRate: .fps30))
    }

    func testAWaitingDefaultEqualToTheActiveFormatAnnouncesNothing() {
        var state = SourceFormatState(initial: start)
        _ = state.defaultSet(resolution: .hd1080, frameRate: .fps60, sourceHasConsumers: true)

        XCTAssertNil(state.sourceBecameIdle())
        XCTAssertNil(state.pending)
    }

    func testGoingIdleWithNothingWaitingChangesNothing() {
        var state = SourceFormatState(initial: start)
        state.sourceClientSet(resolution: .hd720, frameRate: .fps30)

        XCTAssertNil(state.sourceBecameIdle())
        XCTAssertEqual(
            state.active, StreamFormatSelection(resolution: .hd720, frameRate: .fps30),
            "an app's choice stays until the next change"
        )
    }

    func testAWaitingDefaultAppliesOnce() {
        var state = SourceFormatState(initial: start)
        _ = state.defaultSet(resolution: .hd720, frameRate: nil, sourceHasConsumers: true)
        XCTAssertNotNil(state.sourceBecameIdle())

        state.sourceClientSet(resolution: .uhd4k, frameRate: nil)
        XCTAssertNil(state.sourceBecameIdle(), "a second idle must not re-apply the old default")
        XCTAssertEqual(state.active.resolution, .uhd4k)
    }

    // MARK: - An app's own choice

    func testAnAppsChoiceAppliesAtOnceAndLeavesTheDefault() {
        var state = SourceFormatState(initial: start)

        XCTAssertTrue(state.sourceClientSet(resolution: .hd720, frameRate: nil))
        XCTAssertTrue(state.sourceClientSet(resolution: nil, frameRate: .fps30))

        XCTAssertEqual(state.active, StreamFormatSelection(resolution: .hd720, frameRate: .fps30))
        XCTAssertEqual(state.preferred, start)
    }

    func testAnAppChoosingTheActiveFormatChangesNothing() {
        var state = SourceFormatState(initial: start)

        XCTAssertFalse(state.sourceClientSet(resolution: .hd1080, frameRate: .fps60))
        XCTAssertFalse(state.sourceClientSet(resolution: nil, frameRate: nil))
        XCTAssertEqual(state.active, start)
    }
}
