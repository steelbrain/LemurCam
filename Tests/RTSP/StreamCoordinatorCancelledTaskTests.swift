import Foundation
@testable import LemurCam
import XCTest

/// A finished ONVIF resolve, and a reconnect whose wait ended, checked that they were
/// not cancelled and then hopped to the main actor to act. Main-queue work queued in
/// between ran first: the last consumer leaving or the popover closing paused the
/// stream, cancelled the resolve and showed the camera as disconnected, and the hop
/// then connected anyway, streaming with no consumer, or scheduled a reconnect that
/// showed "Reconnecting…" while paused; a switch to another camera was followed by a
/// second connect to it. Both now act with no suspension after the check. Cameras and
/// the scan are stubbed; nothing goes on the network.
@MainActor
internal final class StreamCoordinatorCancelledTaskTests: XCTestCase {
    private static let storedURI = "rtsp://192.168.79.20:554/stored"

    private var fixture: CoordinatorHarness?

    override func setUp() async throws {
        try await super.setUp()
        fixture = nil
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// Runs `action` on the main queue behind work about to be queued there. Each
    /// block holds the main thread while the next main-actor job of the task under
    /// test queues, so the block after the last hold queues behind those jobs.
    @MainActor
    private final class MainQueueHolds {
        var action: (() -> Void)?
        private(set) var hasRun = false

        /// Off the main actor, or on it.
        nonisolated func run(afterHolds holds: Int, each seconds: TimeInterval = 0.2) {
            DispatchQueue.main.async {
                Thread.sleep(forTimeInterval: seconds)
                if holds > 1 {
                    self.run(afterHolds: holds - 1, each: seconds)
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.fire() }
                    }
                }
            }
        }

        private func fire() {
            hasRun = true
            action?()
        }
    }

    // MARK: - ONVIF resolve

    /// The saved address does not answer and the scan finds nothing, so the resolve
    /// fails with a stored URI to fall back to; demand goes as it finishes.
    func testAResolveFinishingAsDemandGoesDoesNotConnect() async throws {
        let (harness, camera, drop) = try makeONVIFCamera(storedURI: Self.storedURI)
        var connectsBefore: Int?
        drop.action = {
            connectsBefore = harness.pipeline.connectedURLs.count
            harness.coordinator.previewStore.isPreviewEnabled = false
        }

        harness.coordinator.previewStore.isPreviewEnabled = true
        let dropped = await waitUntil(timeout: 5) { drop.hasRun }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(dropped)
        XCTAssertEqual(harness.pipeline.connectedURLs.count, connectsBefore, "no connect after demand went")
        XCTAssertEqual(harness.status(camera), .disconnected)
        XCTAssertFalse(harness.coordinator.hasPendingRetry)
        XCTAssertNil(harness.coordinator.placeholderMessage)
    }

    /// No stored URI: the failure schedules a reconnect, which must not outlive the
    /// pause.
    func testAFailedResolveFinishingAsDemandGoesDoesNotScheduleAReconnect() async throws {
        let (harness, camera, drop) = try makeONVIFCamera(storedURI: nil)
        drop.action = { harness.coordinator.previewStore.isPreviewEnabled = false }

        harness.coordinator.previewStore.isPreviewEnabled = true
        let dropped = await waitUntil(timeout: 5) { drop.hasRun }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(dropped)
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty)
        XCTAssertFalse(harness.coordinator.hasPendingRetry, "a reconnect while paused")
        XCTAssertEqual(harness.status(camera), .disconnected)
        XCTAssertNil(harness.coordinator.placeholderMessage, "the placeholder of a reconnect while paused")
    }

    /// A coordinator and an ONVIF camera saved at a LAN address where nothing answers.
    /// Its scan finds nothing and has the returned holds run their action right
    /// behind the end of the resolve.
    private func makeONVIFCamera(storedURI: String?) throws -> (CoordinatorHarness, UUID, MainQueueHolds) {
        let holds = MainQueueHolds()
        let harness = CoordinatorHarness(onvifEnvironment: ONVIFResolveEnvironment(
            scan: {
                // The finishing resolve hops to the main actor three times before the
                // resolving task checks whether it was cancelled: the rest of the
                // resolve, and its way back out of the task group.
                holds.run(afterHolds: 3)
                return []
            },
            makeClient: { info, credentials in
                ONVIFClient(
                    host: info.host, port: info.port, username: credentials?.username,
                    password: credentials?.password, useHTTPS: info.useHTTPS,
                    configuration: ONVIFStubURLProtocol.configuration()
                )
            }
        ))
        fixture = harness
        try harness.manager.addSource(
            name: "Porch",
            sourceType: .onvif(ONVIFSourceInfo(
                deviceUUID: ONVIFResolveFixture.deviceUUID, host: "192.168.79.20", port: 80,
                selectedProfileToken: "main", streamURI: storedURI
            )),
            credentials: ONVIFResolveFixture.credentials
        )
        return (harness, try XCTUnwrap(harness.manager.sources.last?.id), holds)
    }

    // MARK: - Reconnect

    /// Another camera is picked just as the failed one's reconnect wait ends: the
    /// camera picked is connected to once, not again by the stale reconnect.
    func testPickingAnotherCameraAsAReconnectWakesConnectsItOnce() async throws {
        let harness = CoordinatorHarness()
        fixture = harness
        let cameraA = try XCTUnwrap(harness.addRTSP("cam-a"))
        let cameraB = try XCTUnwrap(harness.addRTSP("cam-b"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        harness.pipeline.emit(.error("boom"))
        let reconnecting = await waitUntil { harness.status(cameraA) == .reconnecting }
        XCTAssertTrue(reconnecting)

        // Holds the main thread across the moment the reconnect wakes, then switches.
        let holds = MainQueueHolds()
        holds.action = { harness.manager.setActiveSource(id: cameraB) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.reconnectBackoffBase - 0.2) {
            holds.run(afterHolds: 1, each: 0.5)
        }
        let switched = await waitUntil(timeout: Tuning.reconnectBackoffBase + 3) { holds.hasRun }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(switched)
        XCTAssertEqual(harness.pipeline.connectedURLs.last, "rtsp://cam-b")
        let connected = harness.pipeline.connectedURLs
        XCTAssertEqual(connected.filter { $0 == "rtsp://cam-b" }.count, 1, "\(connected)")
        XCTAssertFalse(harness.coordinator.hasPendingRetry)
    }
}
