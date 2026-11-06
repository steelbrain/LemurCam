@testable import LemurCam
import XCTest

/// A resolve that found its camera at another address rules out the stored stream URI:
/// that URI names the address the camera left, where another device may answer now.
/// The overall deadline's failure did not say a move was found, so when it passed while
/// the camera was asked at the new address, the stored URI was connected to with the
/// saved login. It now carries the move. The fallback also reads the URI saved when the
/// resolve fails, not the copy it started with. Cameras and scans are stubbed; nothing
/// goes on the network.
@MainActor
internal final class ONVIFResolveDeadlineTests: XCTestCase {
    /// Runs on the main actor while the stub scan runs.
    @MainActor
    private final class ScanAction {
        var action: () -> Void = {}

        func run() {
            action()
        }
    }

    private var fixture: ONVIFResolveFixture?
    private var coordinatorFixture: CoordinatorHarness?
    private var silentHosts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        fixture = ONVIFResolveFixture()
        coordinatorFixture = nil
        silentHosts = []
    }

    override func tearDown() async throws {
        silentHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        fixture?.cleanUp()
        fixture = nil
        coordinatorFixture?.cleanUp()
        coordinatorFixture = nil
        try await super.tearDown()
    }

    /// Nothing answers at the saved address. The scan finds the camera at another one,
    /// where it takes the request and never answers, and the deadline passes there.
    func testRunningOutOfTimeAfterTheCameraWasFoundElsewhereRulesOutTheStoredURI() async throws {
        let harness = try XCTUnwrap(fixture)
        ONVIFStubURLProtocol.registerSilent(host: "192.168.79.11")
        silentHosts.append("192.168.79.11")
        let source = try harness.addCamera(host: "192.168.79.10")

        let result = await StreamCoordinator.resolveONVIFStreamURI(
            params: try harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.79.11")]),
            timeout: 1
        )

        guard case .failure(let failure) = result, case .timedOut? = failure.error as? ONVIFError else {
            XCTFail("expected the deadline to pass, got \(result)")
            return
        }
        XCTAssertTrue(failure.cameraMoved, "the stored URI names the address the camera left")
        XCTAssertFalse(failure.allowsStoredURI)
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.79.11", "the move was saved before asking there")
    }

    /// The deadline passes during the scan, before any move was found: the stored URI
    /// is still the fallback.
    func testRunningOutOfTimeBeforeAMoveWasFoundKeepsTheFallback() async throws {
        let harness = try XCTUnwrap(fixture)
        let source = try harness.addCamera(host: "192.168.79.12")

        let result = await StreamCoordinator.resolveONVIFStreamURI(
            params: try harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.79.13")]) {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            },
            timeout: 1
        )

        guard case .failure(let failure) = result, case .timedOut? = failure.error as? ONVIFError else {
            XCTFail("expected the deadline to pass, got \(result)")
            return
        }
        XCTAssertFalse(failure.cameraMoved)
        XCTAssertTrue(failure.allowsStoredURI)
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.79.12")
    }

    /// The saved stream URI changes while the resolve runs (here a move saved during
    /// the scan, which then finds nothing): the fallback connects to the URI saved now,
    /// not to the copy the resolve started with, which names the address left.
    func testTheFallbackIsTheStreamURISavedNow() async throws {
        let saved = ONVIFSourceInfo(
            deviceUUID: ONVIFResolveFixture.deviceUUID, host: "192.168.79.14", port: 80,
            selectedProfileToken: "main", streamURI: "rtsp://192.168.79.14:554/main"
        )
        var moved = saved
        moved.host = "192.168.79.15"
        let duringScan = ScanAction()
        let harness = CoordinatorHarness(onvifEnvironment: ONVIFResolveEnvironment(
            scan: {
                await duringScan.run()
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
        coordinatorFixture = harness
        try harness.manager.addSource(
            name: "Porch", sourceType: .onvif(saved), credentials: ONVIFResolveFixture.credentials
        )
        let camera = try XCTUnwrap(harness.manager.sources.last?.id)
        duringScan.action = { [manager = harness.manager] in
            manager.updateONVIFAddress(id: camera, from: saved, to: moved)
        }

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://192.168.79.15:554/main"])
    }
}
