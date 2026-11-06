@testable import LemurCam
import XCTest

/// Runs the Local Network hint's gate against the state `StreamCoordinator` really
/// leaves a failed LAN camera in. The failure schedules a reconnect in the same
/// main-actor turn, so the popover only ever sees `.reconnecting` with the error
/// message, never `.error`.
@MainActor
internal final class LocalNetworkHintAfterFailureTests: XCTestCase {
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

    private func hintShows(_ harness: CoordinatorHarness, _ id: UUID) -> Bool {
        guard let source = harness.manager.sources.first(where: { $0.id == id }) else { return false }
        return LocalNetworkGuidance.isLikelyBlocked(
            host: LocalNetworkGuidance.host(for: source), status: harness.status(id) ?? .pending,
            errorMessage: harness.manager.errorMessages[id]
        )
    }

    func testAFailedLANCameraShowsTheHint() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("192.168.1.20"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://192.168.1.20"])
        XCTAssertFalse(hintShows(harness, camera))

        harness.pipeline.emit(.error("No route to host"))
        let failed = await waitUntil { harness.status(camera) == .reconnecting }
        XCTAssertTrue(failed)
        XCTAssertTrue(hintShows(harness, camera))
    }

    func testADisconnectedLANCameraDoesNotShowTheHint() async throws {
        let harness = try XCTUnwrap(fixture)
        let camera = try XCTUnwrap(harness.addRTSP("192.168.1.20"))
        harness.coordinator.previewStore.isPreviewEnabled = true

        harness.pipeline.emit(.disconnected)
        let reconnecting = await waitUntil { harness.status(camera) == .reconnecting }
        XCTAssertTrue(reconnecting)
        XCTAssertFalse(hintShows(harness, camera))
    }
}
