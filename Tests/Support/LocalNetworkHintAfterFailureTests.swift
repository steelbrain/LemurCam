@testable import LemurCam
import XCTest

/// Runs the Local Network hint's gate against the state `StreamCoordinator` really
/// leaves a failed LAN camera in. The failure schedules a reconnect in the same
/// main-actor turn, so the popover only ever sees `.reconnecting` with the error
/// message, never `.error`. The hint used to show for any error message, including
/// ones from a camera that answered; it now needs a failure that never reached the
/// host. ONVIF cameras are stubbed, so nothing goes on the network.
@MainActor
internal final class LocalNetworkHintAfterFailureTests: XCTestCase {
    private var harnesses: [CoordinatorHarness] = []
    private var stubbedHosts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        harnesses = []
        stubbedHosts = []
    }

    override func tearDown() async throws {
        harnesses.forEach { $0.cleanUp() }
        harnesses = []
        stubbedHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        stubbedHosts = []
        try await super.tearDown()
    }

    private func makeHarness(onvifEnvironment: ONVIFResolveEnvironment = .live) -> CoordinatorHarness {
        let harness = CoordinatorHarness(onvifEnvironment: onvifEnvironment)
        harnesses.append(harness)
        return harness
    }

    private func hintShows(_ harness: CoordinatorHarness, _ id: UUID) -> Bool {
        guard let source = harness.manager.sources.first(where: { $0.id == id }) else { return false }
        return LocalNetworkGuidance.isLikelyBlocked(
            host: LocalNetworkGuidance.host(for: source), status: harness.status(id) ?? .pending,
            hostUnreachable: harness.manager.unreachableSourceIDs.contains(id)
        )
    }

    /// Starts streaming `host` and fails its connection with `failure`. Returns the
    /// camera once the coordinator shows it waiting to reconnect.
    private func failedCamera(
        _ harness: CoordinatorHarness, host: String, _ failure: RTSPStreamPipeline.State
    ) async throws -> UUID {
        let camera = try XCTUnwrap(harness.addRTSP(host))
        harness.coordinator.previewStore.isPreviewEnabled = true
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host)"])
        XCTAssertFalse(hintShows(harness, camera))
        harness.pipeline.emit(failure)
        let failed = await waitUntil { harness.status(camera) == .reconnecting }
        XCTAssertTrue(failed)
        return camera
    }

    func testALANCameraThatCantBeReachedShowsTheHint() async throws {
        let harness = makeHarness()
        let unreachable = RTSPStreamPipeline.State.error("No route to host", hostUnreachable: true)
        let camera = try await failedCamera(harness, host: "192.168.1.20", unreachable)

        XCTAssertTrue(hintShows(harness, camera))

        // The next attempt starting clears the failure, and the hint with it.
        harness.pipeline.emit(.connecting)
        let connecting = await waitUntil { harness.status(camera) == .connecting }
        XCTAssertTrue(connecting)
        XCTAssertFalse(hintShows(harness, camera))
    }

    func testALANCameraThatAnsweredDoesNotShowTheHint() async throws {
        let messages = [
            "Authentication failed", "404 response: Not Found",
            RTSPStreamPipeline.NoVideoStreamError().localizedDescription,
            RTSPStreamPipeline.StreamStallError().localizedDescription
        ]
        for message in messages {
            let harness = makeHarness()
            let camera = try await failedCamera(harness, host: "192.168.1.20", .error(message))
            XCTAssertEqual(harness.manager.errorMessages[camera], message)
            XCTAssertFalse(hintShows(harness, camera), message)
        }
    }

    /// Local Network privacy doesn't gate loopback.
    func testALoopbackCameraDoesNotShowTheHint() async throws {
        let harness = makeHarness()
        let camera = try await failedCamera(harness, host: "127.0.0.1", .error("Timeout", hostUnreachable: true))
        XCTAssertFalse(hintShows(harness, camera))
    }

    func testADisconnectedLANCameraDoesNotShowTheHint() async throws {
        let harness = makeHarness()
        let camera = try XCTUnwrap(harness.addRTSP("192.168.1.20"))
        harness.coordinator.previewStore.isPreviewEnabled = true

        harness.pipeline.emit(.disconnected)
        let reconnecting = await waitUntil { harness.status(camera) == .reconnecting }
        XCTAssertTrue(reconnecting)
        XCTAssertFalse(hintShows(harness, camera))
    }

    // MARK: - ONVIF

    /// An ONVIF camera with no stored stream URI whose resolve failed. `reply` is what
    /// the stubbed camera answers; nil makes it answer nothing.
    private func failedONVIFCamera(host: String, reply: ONVIFStubURLProtocol.Reply?) async throws
        -> (CoordinatorHarness, UUID) {
        if let reply {
            stubbedHosts.append(host)
            ONVIFStubURLProtocol.register(host: host) { _, _ in reply }
        }
        let harness = makeHarness(onvifEnvironment: ONVIFResolveEnvironment(
            scan: { [] },
            makeClient: { info, _ in
                ONVIFClient(host: info.host, port: info.port, username: nil, password: nil,
                            configuration: ONVIFStubURLProtocol.configuration())
            }
        ))
        try harness.manager.addSource(name: "Porch", sourceType: .onvif(ONVIFSourceInfo(
            host: host, port: 80, selectedProfileToken: "main"
        )))
        let camera = try XCTUnwrap(harness.manager.sources.last?.id)
        harness.coordinator.previewStore.isPreviewEnabled = true
        let failed = await waitUntil(timeout: 5) { harness.status(camera) == .reconnecting }
        XCTAssertTrue(failed)
        return (harness, camera)
    }

    func testAnONVIFCameraThatGaveNoAnswerShowsTheHint() async throws {
        let (harness, camera) = try await failedONVIFCamera(host: "192.168.1.31", reply: nil)
        XCTAssertTrue(hintShows(harness, camera))
    }

    func testAnONVIFCameraThatRefusedTheLoginDoesNotShowTheHint() async throws {
        let (harness, camera) = try await failedONVIFCamera(host: "192.168.1.32", reply: .init(status: 401))
        XCTAssertEqual(harness.manager.errorMessages[camera], ONVIFError.authenticationFailed.localizedDescription)
        XCTAssertFalse(hintShows(harness, camera))
    }
}
