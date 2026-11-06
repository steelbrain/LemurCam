@testable import LemurCam
import XCTest

/// Locks the active camera's status while its stream is paused for lack of demand.
/// The pause cancels the stream silently, which fires no state change, so Settings
/// kept showing "Connected" for a stream that was down, or "Reconnecting…" for good
/// when a reconnect had been pending. Picking a camera while nothing needed the
/// stream left whatever status it had, such as the launch check's "Connected".
@MainActor
internal final class StreamCoordinatorPauseStatusTests: XCTestCase {
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

    func testPausingShowsTheActiveCameraAsDisconnected() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)

        harness.coordinator.previewStore.isPreviewEnabled = false

        XCTAssertEqual(harness.status(camera), .disconnected)
        XCTAssertNil(harness.manager.errorMessages[camera])
    }

    func testPausingWhileReconnectingDropsTheRetryAndItsError() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        harness.pipeline.emit(.error("boom"))
        let reconnecting = await waitUntil { harness.status(camera) == .reconnecting }
        XCTAssertTrue(reconnecting)
        XCTAssertEqual(harness.manager.errorMessages[camera], "boom")

        harness.coordinator.previewStore.isPreviewEnabled = false

        XCTAssertFalse(harness.coordinator.hasPendingRetry)
        XCTAssertEqual(harness.status(camera), .disconnected)
        XCTAssertNil(harness.manager.errorMessages[camera])
    }

    /// A state change already on its way to the main actor when the pause cancelled
    /// the stream must not revive the paused camera's status or schedule a retry.
    func testAStateChangeFromThePausedStreamIsIgnored() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true

        harness.pipeline.emit(.error("late"))
        harness.coordinator.previewStore.isPreviewEnabled = false
        let retried = await waitUntil(timeout: 0.3) { harness.coordinator.hasPendingRetry }

        XCTAssertFalse(retried, "nothing needs the stream, so nothing may reconnect it")
        XCTAssertEqual(harness.status(camera), .disconnected)
        XCTAssertNil(harness.manager.errorMessages[camera])
    }

    /// The launch reachability check marks inactive cameras "Connected" when they
    /// answer. Making one active while nothing needs the stream must not keep that.
    func testSelectingACameraWhileNothingNeedsTheStreamShowsItDisconnected() throws {
        let harness = try XCTUnwrap(fixture)
        _ = harness.addRTSP("cam-a")
        let cameraB = try XCTUnwrap(harness.addRTSP("cam-b"))
        harness.manager.updateConnectionStatus(for: cameraB, status: .connected)

        harness.manager.setActiveSource(id: cameraB)

        XCTAssertEqual(harness.status(cameraB), .disconnected)
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty, "nothing needs the stream")
    }
}
