@testable import LemurCam
import XCTest

/// Locks when a failed ONVIF stream-URI resolve falls back to the stream URI saved
/// with the camera. A refused login or a SOAP fault fell back too, so after two
/// cameras swapped addresses the saved address, which now belongs to the other
/// camera, got an RTSP login on every retry. Those failures now show their error and
/// retry with backoff; a camera that does not answer still falls back, since that is
/// how one with a broken ONVIF service but working RTSP streams, unless the scan
/// found it at another address: the stored URI names the address it left. That case
/// fell back on the new address's error, which hid a refused login at the saved one.
/// Cameras are stubbed with `ONVIFStubURLProtocol`; nothing goes on the network.
@MainActor
internal final class StreamCoordinatorONVIFFallbackTests: XCTestCase {
    private static let storedURI = "rtsp://192.168.78.20:554/stored"

    private var fixture: CoordinatorHarness?
    private var stubHosts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        fixture = nil
        stubHosts = []
    }

    override func tearDown() async throws {
        stubHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - The decision

    func testARefusedLoginOrASOAPFaultRulesOutTheStoredURI() {
        XCTAssertFalse(StreamCoordinator.mayFallBackToStoredURI(after: ONVIFError.authenticationFailed))
        XCTAssertFalse(StreamCoordinator.mayFallBackToStoredURI(after: ONVIFError.soapFault("No such profile")))
    }

    func testNoAnswerOrNoWorkingONVIFServiceKeepsTheFallback() {
        let errors: [any Error] = [
            ONVIFError.networkError("Could not connect to the server."), ONVIFError.timedOut,
            ONVIFError.httpStatus(404), ONVIFError.parseError, ONVIFError.invalidURL, ONVIFXML.Rejection.tooLarge
        ]
        for error in errors {
            XCTAssertTrue(StreamCoordinator.mayFallBackToStoredURI(after: error), "\(error)")
            XCTAssertTrue(ONVIFResolveFailure(error).allowsStoredURI, "\(error)")
        }
        XCTAssertFalse(ONVIFResolveFailure(ONVIFError.authenticationFailed).allowsStoredURI)
    }

    /// Whatever the error at the new address, a camera found there never falls back.
    func testACameraFoundAtAnotherAddressRulesOutTheStoredURI() {
        let errors: [any Error] = [
            ONVIFError.networkError("Could not connect to the server."), ONVIFError.timedOut,
            ONVIFError.httpStatus(404), ONVIFError.authenticationFailed
        ]
        for error in errors {
            XCTAssertFalse(ONVIFResolveFailure(error, cameraMoved: true).allowsStoredURI, "\(error)")
        }
    }

    // MARK: - Through the coordinator

    /// The camera that took the saved LAN address refuses the login, and the scan
    /// does not find this camera anywhere.
    func testARefusedLoginShowsTheErrorAndRetriesWithoutConnecting() async throws {
        let (harness, camera) = try makeCamera(at: "192.168.78.21", replying: ONVIFStubURLProtocol.Reply(status: 401))

        harness.coordinator.previewStore.isPreviewEnabled = true
        let reconnecting = await waitUntil(timeout: 5) { harness.status(camera) == .reconnecting }

        XCTAssertTrue(reconnecting)
        XCTAssertTrue(harness.coordinator.hasPendingRetry)
        XCTAssertEqual(harness.manager.errorMessages[camera], "Authentication failed")
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty, "no RTSP login may go to the saved address")
    }

    func testASOAPFaultShowsTheErrorAndRetriesWithoutConnecting() async throws {
        let fault = Data("""
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault>
            <s:Code><s:Value>s:Sender</s:Value></s:Code>
            <s:Reason><s:Text xml:lang="en">No such profile</s:Text></s:Reason></s:Fault></s:Body></s:Envelope>
            """.utf8)
        let (harness, camera) = try makeCamera(
            at: "192.168.78.22", replying: ONVIFStubURLProtocol.Reply(status: 400, body: fault)
        )

        harness.coordinator.previewStore.isPreviewEnabled = true
        let reconnecting = await waitUntil(timeout: 5) { harness.status(camera) == .reconnecting }

        XCTAssertTrue(reconnecting)
        XCTAssertEqual(harness.manager.errorMessages[camera], "ONVIF error: No such profile")
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty)
    }

    /// Nothing answers at the saved address (no stub is registered for it).
    func testACameraThatDoesNotAnswerStillFallsBack() async throws {
        let (harness, _) = try makeCamera(at: "192.168.78.23", replying: nil)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, [Self.storedURI])
    }

    /// The reported case: the camera that took the saved address refuses the login,
    /// and the scan finds this camera at a new address, where it does not answer. The
    /// stored URI's address got an RTSP login with the saved credentials.
    func testARefusedLoginWithTheCameraFoundElsewhereDoesNotFallBack() async throws {
        let (harness, camera) = try makeCamera(
            at: "192.168.78.24", replying: ONVIFStubURLProtocol.Reply(status: 401),
            scanFinds: [ONVIFResolveFixture.device(host: "192.168.78.25")]
        )

        harness.coordinator.previewStore.isPreviewEnabled = true
        let reconnecting = await waitUntil(timeout: 5) { harness.status(camera) == .reconnecting }

        XCTAssertTrue(reconnecting)
        XCTAssertTrue(harness.coordinator.hasPendingRetry)
        XCTAssertNotNil(harness.manager.errorMessages[camera])
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty, "no RTSP login may go to the stored URI's address")
    }

    /// Nothing answers at the saved address nor where the scan finds the camera: the
    /// stored URI names the address the camera left.
    func testACameraFoundElsewhereThatDoesNotAnswerThereDoesNotFallBack() async throws {
        let (harness, camera) = try makeCamera(
            at: "192.168.78.26", replying: nil, scanFinds: [ONVIFResolveFixture.device(host: "192.168.78.27")]
        )

        harness.coordinator.previewStore.isPreviewEnabled = true
        let reconnecting = await waitUntil(timeout: 5) { harness.status(camera) == .reconnecting }

        XCTAssertTrue(reconnecting)
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty)
    }

    /// A coordinator and an ONVIF camera saved, with credentials and a stored stream
    /// URI, at a LAN address that answers every request with `reply` (nothing
    /// answers when nil). The scan finds `scanFinds`.
    private func makeCamera(
        at host: String, replying reply: ONVIFStubURLProtocol.Reply?, scanFinds devices: [DiscoveredDevice] = []
    ) throws -> (CoordinatorHarness, UUID) {
        if let reply {
            stubHosts.append(host)
            ONVIFStubURLProtocol.register(host: host) { _, _ in reply }
        }
        let harness = CoordinatorHarness(onvifEnvironment: ONVIFResolveEnvironment(
            scan: { devices },
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
                deviceUUID: ONVIFResolveFixture.deviceUUID, host: host, port: 80,
                selectedProfileToken: "main", streamURI: Self.storedURI
            )),
            credentials: ONVIFResolveFixture.credentials
        )
        return (harness, try XCTUnwrap(harness.manager.sources.last?.id))
    }
}
