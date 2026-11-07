@testable import LemurCam
import XCTest

/// Pins that the camera's measured frame rate reaches the jitter buffer through the
/// coordinator, only from the stream it runs. Seen through priming: at 60 fps the
/// buffer holds twice the frames before it starts sending, the same ~200 ms.
@MainActor
internal final class StreamCoordinatorFrameRateTests: XCTestCase {
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

    func testTheCamerasFrameRateSetsTheDrainRate() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-60"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        await connect(camera, in: harness)

        harness.pipeline.emitVideoFrameRate(60)
        let priming = JitterBufferSizing(drainFPS: 60).primingThreshold
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold)
        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames, "at 60 fps it holds 200 ms: more frames")
        try harness.deliverDecodedFrames(priming - Tuning.jitterBufferPrimingThreshold)
        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames)
    }

    /// The previous camera's rate, reported as the switch happens, must not set the
    /// next camera's drain rate.
    func testThePreviousCamerasFrameRateIsIgnored() async throws {
        let harness = try XCTUnwrap(fixture)
        let front = try XCTUnwrap(harness.addRTSP("front"))
        let back = try XCTUnwrap(harness.addRTSP("back"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        let frontConnection = harness.pipeline.latestConnection
        await connect(front, in: harness)

        harness.manager.setActiveSource(id: back)
        harness.pipeline.emitVideoFrameRate(60, connection: frontConnection)
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold)

        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames, "the back camera drains at the default rate")
    }

    /// A new connection starts at the default rate: the 60 fps camera's rate doesn't
    /// carry over to the next camera, whose own rate is not known yet.
    func testANewConnectionStartsAtTheDefaultRate() async throws {
        let harness = try XCTUnwrap(fixture)
        let front = try XCTUnwrap(harness.addRTSP("front"))
        let back = try XCTUnwrap(harness.addRTSP("back"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        await connect(front, in: harness)
        harness.pipeline.emitVideoFrameRate(60)

        harness.manager.setActiveSource(id: back)
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold)

        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames)
    }

    /// Report the latest connection streaming and wait for the camera to show connected.
    private func connect(_ camera: UUID, in harness: CoordinatorHarness) async {
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)
    }
}
