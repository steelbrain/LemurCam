@testable import LemurCam
import XCTest

/// Locks out state changes from a pipeline connection the coordinator no longer
/// runs. Each change hops to the main actor, so an error or end reported by a
/// stream that was just replaced could land after the coordinator connected again,
/// be taken for news about the new connection, mark that camera failed and
/// schedule a reconnect that tore the new stream down. Each change now carries the
/// connection it belongs to, and only the current connection's changes apply.
@MainActor
internal final class StreamCoordinatorStaleStateTests: XCTestCase {
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

    func testAnErrorFromThePreviousCamerasStreamIsIgnoredAfterSwitching() async throws {
        let harness = try XCTUnwrap(fixture)
        let front = try XCTUnwrap(harness.addRTSP("front"))
        let back = try XCTUnwrap(harness.addRTSP("back"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        let frontConnection = harness.pipeline.latestConnection
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(front) == .connected }
        XCTAssertTrue(connected)

        // The front stream fails just as the back camera is picked: its error is
        // still on its way to the main actor when the switch connects to the back.
        harness.pipeline.emit(.error("front stream failed"), connection: frontConnection)
        harness.manager.setActiveSource(id: back)
        XCTAssertEqual(harness.pipeline.connectedURLs.last, "rtsp://back")
        let retried = await waitUntil(timeout: 0.3) { harness.coordinator.hasPendingRetry }

        XCTAssertFalse(retried, "the back camera's new stream must not be torn down for the front's error")
        XCTAssertEqual(harness.status(back), .connecting)
        XCTAssertNil(harness.manager.errorMessages[back])
    }

    func testAnEndFromBeforeAReconnectIsIgnored() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        let earlier = harness.pipeline.latestConnection
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)

        // The stream ends just as demand goes and comes back, and the resume
        // connects again before the end reaches the main actor.
        harness.pipeline.emit(.disconnected, connection: earlier)
        harness.coordinator.previewStore.isPreviewEnabled = false
        harness.coordinator.previewStore.isPreviewEnabled = true
        XCTAssertEqual(harness.pipeline.connectedURLs.count, 2)
        let retried = await waitUntil(timeout: 0.3) { harness.coordinator.hasPendingRetry }

        XCTAssertFalse(retried, "the new connection must not be retried for the old one's end")
        XCTAssertEqual(harness.status(camera), .connecting)
    }

    /// The current connection's changes still apply.
    func testAnErrorFromTheCurrentConnectionSchedulesAReconnect() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true

        harness.pipeline.emit(.error("boom"), connection: harness.pipeline.latestConnection)
        let reconnecting = await waitUntil { harness.status(camera) == .reconnecting }

        XCTAssertTrue(reconnecting)
        XCTAssertTrue(harness.coordinator.hasPendingRetry)
        XCTAssertEqual(harness.manager.errorMessages[camera], "boom")
    }
}
