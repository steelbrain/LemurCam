@testable import LemurCam
import XCTest

/// Locks what the virtual camera shows when the active camera changes while an app
/// watches. The old stream is cancelled silently, which fires no state change, so
/// the jitter buffer was never reset and its drain timer kept re-sending the old
/// camera's last frame at 30 fps. Picking "None" made that frame alternate with the
/// "No camera available" placeholder, and an ONVIF camera showed the old camera
/// frozen until its stream address was resolved.
@MainActor
internal final class StreamCoordinatorSourceSwitchTests: XCTestCase {
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

    func testChoosingNoCameraStopsSendingTheOldCamerasFrames() async throws {
        let harness = try XCTUnwrap(fixture)
        try await streamFrames(from: "cam-a", in: harness)

        harness.manager.setActiveSource(id: nil)

        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames, "the old frame must not keep being sent")
        XCTAssertEqual(harness.coordinator.placeholderMessage, "No camera available in LemurCam")
    }

    func testSwitchingToAnONVIFCameraShowsConnectingWhileItResolves() async throws {
        let harness = try XCTUnwrap(fixture)
        try await streamFrames(from: "cam-a", in: harness)
        // Port 1 on loopback refuses at once and no device UUID means no scan, so the
        // resolve stays on this machine; the assertions run before it finishes.
        let info = ONVIFSourceInfo(
            deviceUUID: nil, host: "127.0.0.1", port: 1, selectedProfileToken: "profile_1", streamURI: nil
        )
        try harness.manager.addSource(name: "onvif", sourceType: .onvif(info))
        let onvif = try XCTUnwrap(harness.manager.sources.last?.id)

        harness.manager.setActiveSource(id: onvif)

        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames, "the old camera must not stay frozen on screen")
        XCTAssertEqual(harness.coordinator.placeholderMessage, "Connecting in LemurCam")
        XCTAssertEqual(harness.status(onvif), .connecting)
    }

    /// Connect an RTSP camera through preview demand and feed it enough decoded
    /// frames to start the jitter buffer's drain timer.
    private func streamFrames(from name: String, in harness: CoordinatorHarness) async throws {
        let camera = try XCTUnwrap(harness.addRTSP(name))
        harness.coordinator.previewStore.isPreviewEnabled = true
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold)
        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames)
    }
}
