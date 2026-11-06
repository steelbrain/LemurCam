@testable import LemurCam
import XCTest

/// Locks out decoded frames and stream info from a pipeline connection the
/// coordinator no longer runs. A cancelled stream's decoder can still deliver a
/// frame, and its stream info and preview renders hop to the main actor, so after
/// a camera switch the old camera's last frame could be queued for the virtual
/// camera, shown in the preview, or its resolution and codec shown in the Preview
/// pane, and a stale frame could pass for the new stream's first decoded one.
/// Frames and stream info now carry the connection they came from, and only the
/// current connection's get through.
@MainActor
internal final class StreamCoordinatorStaleOutputTests: XCTestCase {
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

    func testFramesFromThePreviousCamerasStreamAreNotSentAfterSwitching() async throws {
        let harness = try XCTUnwrap(fixture)
        let front = try XCTUnwrap(harness.addRTSP("front"))
        let back = try XCTUnwrap(harness.addRTSP("back"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        let frontConnection = harness.pipeline.latestConnection
        await connect(front, in: harness)

        harness.manager.setActiveSource(id: back)
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold, from: frontConnection)

        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames, "the front's frames must not be sent")
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold)
        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames, "the back camera's own frames still go through")
    }

    func testFramesFromAPausedStreamAreNotSent() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        await connect(camera, in: harness)

        harness.coordinator.previewStore.isPreviewEnabled = false
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold)

        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames)
    }

    func testStreamInfoFromThePreviousCameraIsNotShown() async throws {
        let harness = try XCTUnwrap(fixture)
        let front = try XCTUnwrap(harness.addRTSP("front"))
        let back = try XCTUnwrap(harness.addRTSP("back"))
        let preview = harness.coordinator.previewStore
        preview.isPreviewEnabled = true
        let frontConnection = harness.pipeline.latestConnection
        await connect(front, in: harness)

        // The front stream's info is still on its way to the main actor when the
        // back camera is picked.
        harness.pipeline.emitStreamInfo(.init(width: 1920, height: 1080, codec: "H.265"), connection: frontConnection)
        harness.manager.setActiveSource(id: back)
        let shown = await waitUntil(timeout: 0.3) { preview.sourceCodec != nil }
        XCTAssertFalse(shown, "the back camera must not show the front's resolution and codec")

        harness.pipeline.emitStreamInfo(.init(width: 640, height: 360, codec: "H.264"))
        let current = await waitUntil { preview.sourceCodec == "H.264" }
        XCTAssertTrue(current)
        XCTAssertEqual(preview.sourceWidth, 640)
        XCTAssertEqual(preview.sourceHeight, 360)
    }

    /// The current camera's frames reach the preview: the control for the next test.
    func testTheCurrentCamerasFramesReachThePreview() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        let preview = harness.coordinator.previewStore
        preview.isPreviewEnabled = true
        await connect(camera, in: harness)

        try harness.deliverDecodedFrames(2)
        let shown = await waitUntil { preview.latestFrame != nil && preview.estimatedFPS != nil }

        XCTAssertTrue(shown)
    }

    func testAPreviewOfThePreviousCamerasFrameThatLandsAfterSwitchingIsDropped() async throws {
        let harness = try XCTUnwrap(fixture)
        let front = try XCTUnwrap(harness.addRTSP("front"))
        let back = try XCTUnwrap(harness.addRTSP("back"))
        let preview = harness.coordinator.previewStore
        preview.isPreviewEnabled = true
        await connect(front, in: harness)

        // The front's frames are let through and their preview render and frame rate
        // are queued for the main actor, which this test holds until the switch is done.
        try harness.deliverDecodedFrames(2)
        harness.manager.setActiveSource(id: back)
        let shown = await waitUntil(timeout: 0.5) { preview.latestFrame != nil || preview.estimatedFPS != nil }

        XCTAssertFalse(shown, "the back camera's preview must not show the front's frame")
    }

    func testAFrameFromAnEarlierConnectionDoesNotResetTheBackoff() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        let earlier = harness.pipeline.latestConnection
        await connect(camera, in: harness)
        harness.pipeline.emit(.error("dropped"))
        let failed = await waitUntil { harness.coordinator.reconnectFailures == 1 }
        XCTAssertTrue(failed)

        // Demand goes and comes back, so the camera connects again at once.
        harness.coordinator.previewStore.isPreviewEnabled = false
        harness.coordinator.previewStore.isPreviewEnabled = true
        await connect(camera, in: harness)
        try harness.deliverDecodedFrames(1, from: earlier)
        let reset = await waitUntil(timeout: 0.3) { harness.coordinator.reconnectFailures == 0 }

        XCTAssertFalse(reset, "a frame from the dropped stream proves nothing about the new one")
        try harness.deliverDecodedFrames(1)
        let resetByCurrent = await waitUntil { harness.coordinator.reconnectFailures == 0 }
        XCTAssertTrue(resetByCurrent)
    }

    /// Report the latest connection streaming and wait for the camera to show connected.
    private func connect(_ camera: UUID, in harness: CoordinatorHarness) async {
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)
    }
}
