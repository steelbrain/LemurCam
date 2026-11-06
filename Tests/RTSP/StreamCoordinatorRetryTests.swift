@testable import LemurCam
import XCTest

/// Locks reconnect scheduling in `StreamCoordinator`. `onSourceConfigChanged` fires
/// on any source's add, remove, or edit, and `syncToActiveSource()` used to cancel
/// every task before checking whether the active source had changed. Editing another
/// source while the active camera waited to reconnect cancelled that reconnect for
/// good, leaving the status at "Reconnecting". Tasks are now cancelled only when the
/// active source changes.
@MainActor
internal final class StreamCoordinatorRetryTests: XCTestCase {
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

    /// Connect `cam-a` through preview demand, then fail it so a reconnect is pending.
    private func failActiveSource(_ harness: CoordinatorHarness) async throws -> UUID {
        let cameraA = try XCTUnwrap(harness.addRTSP("cam-a"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])

        harness.pipeline.emit(.error("boom"))
        let reconnecting = await waitUntil { harness.status(cameraA) == .reconnecting }
        XCTAssertTrue(reconnecting, "a pipeline error must schedule a reconnect")
        XCTAssertTrue(harness.coordinator.hasPendingRetry)
        return cameraA
    }

    func testAddingAnotherSourceKeepsThePendingReconnect() async throws {
        let harness = try XCTUnwrap(fixture)
        let cameraA = try await failActiveSource(harness)

        _ = harness.addRTSP("cam-b")

        XCTAssertTrue(harness.coordinator.hasPendingRetry, "another source's change must not cancel the reconnect")
        XCTAssertEqual(harness.status(cameraA), .reconnecting)
        let reconnected = await waitUntil(timeout: Tuning.reconnectBackoffBase + 3) {
            harness.pipeline.connectedURLs.count == 2
        }
        XCTAssertTrue(reconnected, "the scheduled reconnect must still run")
        XCTAssertEqual(harness.pipeline.connectedURLs.last, "rtsp://cam-a")
    }

    func testEditingOrRemovingAnotherSourceKeepsThePendingReconnect() async throws {
        let harness = try XCTUnwrap(fixture)
        let cameraA = try await failActiveSource(harness)
        let cameraB = try XCTUnwrap(harness.addRTSP("cam-b"))

        try harness.manager.updateSource(
            id: cameraB, name: "cam-b2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://cam-b2")), credentials: nil
        )
        XCTAssertTrue(harness.coordinator.hasPendingRetry, "editing another source must not cancel the reconnect")

        try harness.manager.removeSource(id: cameraB)
        XCTAssertTrue(harness.coordinator.hasPendingRetry, "removing another source must not cancel the reconnect")
        XCTAssertEqual(harness.status(cameraA), .reconnecting)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"], "nothing reconnects early")
    }

    func testSwitchingTheActiveSourceCancelsTheReconnectAndConnectsTheNewOne() async throws {
        let harness = try XCTUnwrap(fixture)
        _ = try await failActiveSource(harness)
        let cameraB = try XCTUnwrap(harness.addRTSP("cam-b"))

        harness.manager.setActiveSource(id: cameraB)

        XCTAssertFalse(harness.coordinator.hasPendingRetry, "the old source's reconnect is obsolete")
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a", "rtsp://cam-b"])
    }

    func testEditingTheActiveSourceReconnectsAtOnce() async throws {
        let harness = try XCTUnwrap(fixture)
        let cameraA = try await failActiveSource(harness)

        try harness.manager.updateSource(
            id: cameraA, name: "cam-a", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://cam-a2")), credentials: nil
        )

        XCTAssertFalse(harness.coordinator.hasPendingRetry)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a", "rtsp://cam-a2"])
    }
}
