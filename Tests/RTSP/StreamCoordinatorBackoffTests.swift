@testable import LemurCam
import XCTest

/// Locks when the reconnect backoff starts over. It reset on `.streaming`, which the
/// pipeline reports right after PLAY, before any frame decodes. A camera that
/// accepted PLAY and then dropped was retried every 2 s forever, and a stream that
/// never decoded looped through the decode-stall watchdog showing "Connected" most
/// of the time. A newly selected camera also inherited the old one's backoff. The
/// count now starts over on the first decoded frame and when the active source
/// changes or is edited.
@MainActor
internal final class StreamCoordinatorBackoffTests: XCTestCase {
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

    func testDelaysDoubleUpToTheCap() {
        var backoff = ReconnectBackoff()
        let source = ReconnectBackoff.Source(id: UUID(), updatedAt: nil)

        let delays = (0..<6).map { _ in backoff.delayAfterFailure(of: source) }

        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30])
    }

    func testAStreamThatDropsBeforeDecodingKeepsBackingOff() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true

        await connectThenDrop(camera, in: harness)
        await connectThenDrop(camera, in: harness)

        XCTAssertEqual(harness.coordinator.reconnectFailures, 2, "connecting without a decoded frame is no recovery")
    }

    func testTheFirstDecodedFrameResetsTheBackoff() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        await connectThenDrop(camera, in: harness)
        await connectThenDrop(camera, in: harness)

        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)
        try harness.deliverDecodedFrames(1)

        let reset = await waitUntil { harness.coordinator.reconnectFailures == 0 }
        XCTAssertTrue(reset, "a decoded frame proves the stream works")
    }

    func testANewlySelectedCameraStartsFromTheBaseDelay() async throws {
        let harness = try XCTUnwrap(fixture)
        let cameraA = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        await connectThenDrop(cameraA, in: harness)
        await connectThenDrop(cameraA, in: harness)
        let cameraB = try XCTUnwrap(harness.addRTSP("cam-b"))

        harness.manager.setActiveSource(id: cameraB)
        await reconnectThenFail(cameraB, in: harness)

        XCTAssertEqual(harness.coordinator.reconnectFailures, 1, "cam-b must not inherit cam-a's backoff")
    }

    func testEditingTheActiveCameraStartsFromTheBaseDelay() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        await connectThenDrop(camera, in: harness)
        await connectThenDrop(camera, in: harness)

        harness.manager.updateSource(
            id: camera, name: "cam-a", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://cam-a2")), credentials: nil
        )
        await reconnectThenFail(camera, in: harness)

        XCTAssertEqual(harness.coordinator.reconnectFailures, 1)
    }

    /// The camera accepts PLAY, so the pipeline reports `.streaming`, then drops
    /// before a frame decodes.
    private func connectThenDrop(_ camera: UUID, in harness: CoordinatorHarness) async {
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)
        await fail(camera, in: harness)
    }

    /// A switch or edit connects at once. Wait for that attempt's `.connecting` so
    /// the earlier "Reconnecting…" can't pass for the failure that follows.
    private func reconnectThenFail(_ camera: UUID, in harness: CoordinatorHarness) async {
        let connecting = await waitUntil { harness.status(camera) == .connecting }
        XCTAssertTrue(connecting)
        await fail(camera, in: harness)
    }

    private func fail(_ camera: UUID, in harness: CoordinatorHarness) async {
        harness.pipeline.emit(.error("dropped"))
        let reconnecting = await waitUntil { harness.status(camera) == .reconnecting }
        XCTAssertTrue(reconnecting)
    }
}
