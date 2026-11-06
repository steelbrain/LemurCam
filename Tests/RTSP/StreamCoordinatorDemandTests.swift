@testable import LemurCam
import XCTest

/// Locks the AGENTS.md rule that toggling microphone demand must not reconnect a
/// live video stream. `reconcileDemand()` acts only when total demand crosses
/// between none and some, so a consumer that comes and goes while another keeps
/// demand up leaves the stream alone. A reconnect shows up here as another
/// `connect` (or a silent cancel) on the fake pipeline.
@MainActor
internal final class StreamCoordinatorDemandTests: XCTestCase {
    private var fixture: CoordinatorHarness?

    override func setUp() async throws {
        try await super.setUp()
        fixture = CoordinatorHarness()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testMicrophoneToggleDoesNotReconnectALiveVideoStream() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        harness.pipeline.emit(.streaming)
        let streaming = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(streaming)
        let cancelsBefore = harness.pipeline.silentCancels

        harness.coordinator.simulateAudioConsumerChange(active: true)
        harness.coordinator.simulateAudioConsumerChange(active: false)
        harness.coordinator.simulateAudioConsumerChange(active: true)
        harness.coordinator.simulateAudioConsumerChange(active: false)

        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"], "the mic must not reconnect video")
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore, "the mic must not tear video down")
        XCTAssertEqual(harness.status(camera), .connected)
    }

    /// The other direction: preview coming and going while the mic keeps the
    /// stream up must not reconnect the audio it carries.
    func testPreviewToggleWhileMicrophoneInUseDoesNotReconnect() throws {
        let harness = try XCTUnwrap(fixture)
        _ = harness.addRTSP("cam-a")
        harness.coordinator.simulateAudioConsumerChange(active: true)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"], "mic demand alone starts the stream")
        let cancelsBefore = harness.pipeline.silentCancels

        harness.coordinator.previewStore.isPreviewEnabled = true
        harness.coordinator.previewStore.isPreviewEnabled = false

        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore)
    }

    /// When the mic was the only consumer, its stop is a real demand edge and pauses
    /// the stream; its return resumes it.
    func testMicrophoneAsTheOnlyConsumerPausesAndResumesTheStream() throws {
        let harness = try XCTUnwrap(fixture)
        _ = harness.addRTSP("cam-a")
        harness.coordinator.simulateAudioConsumerChange(active: true)
        let cancelsBefore = harness.pipeline.silentCancels

        harness.coordinator.simulateAudioConsumerChange(active: false)
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore + 1, "no demand pauses the stream")

        harness.coordinator.simulateAudioConsumerChange(active: true)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a", "rtsp://cam-a"], "demand resumes it")
    }
}
