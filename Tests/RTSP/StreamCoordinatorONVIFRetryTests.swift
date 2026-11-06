@testable import LemurCam
import XCTest

/// Locks the retry after a failed ONVIF stream-URI resolve. With no stored stream
/// URI to fall back on, the coordinator set the source to error and returned without
/// scheduling a reconnect, so a camera that was offline when LemurCam connected
/// stayed in error until the user intervened. It now retries like any failed connect.
@MainActor
internal final class StreamCoordinatorONVIFRetryTests: XCTestCase {
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

    /// Port 1 on loopback refuses the connection at once, and without a device UUID
    /// no WS-Discovery scan runs, so the resolve fails fast and stays on this machine.
    func testResolveFailureWithoutAStoredURISchedulesAReconnect() async throws {
        let harness = try XCTUnwrap(fixture)
        let info = ONVIFSourceInfo(
            deviceUUID: nil, host: "127.0.0.1", port: 1, selectedProfileToken: "profile_1", streamURI: nil
        )
        harness.manager.addSource(name: "onvif", sourceType: .onvif(info))
        let camera = try XCTUnwrap(harness.manager.sources.last?.id)

        harness.coordinator.previewStore.isPreviewEnabled = true

        let reconnecting = await waitUntil(timeout: 8) { harness.status(camera) == .reconnecting }
        XCTAssertTrue(reconnecting, "a failed ONVIF resolve must schedule a reconnect")
        XCTAssertTrue(harness.coordinator.hasPendingRetry)
        // The resolve's own error is shown: loopback port 1 refuses the connection.
        let message = try XCTUnwrap(harness.manager.errorMessages[camera])
        XCTAssertTrue(message.hasPrefix("Network error:"), message)
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty, "there is no URI to connect to")
    }
}
