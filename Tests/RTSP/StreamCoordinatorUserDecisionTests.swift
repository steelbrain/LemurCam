import Foundation
@testable import LemurCam
import os
import Security
import XCTest

/// What connecting does when what answers at a camera's saved address needs the
/// user's decision: a certificate other than the one the user trusted, an address
/// outside the local network that plain HTTP isn't allowed to, or another device than
/// the camera saved there. Trying again or falling back to the stored stream URI
/// would not change the answer, and the fallback may send the login to another
/// device. A scan would not change it for a certificate or plain HTTP either; another
/// device at the saved address is a sign the camera moved, so the camera is looked
/// for first. The camera shows what to do, and nothing connects until it is edited.
/// Cameras are stubbed with `ONVIFStubURLProtocol`; nothing goes on the network.
@MainActor
internal final class StreamCoordinatorUserDecisionTests: XCTestCase {
    private static let storedURI = "rtsp://192.168.79.40:554/stored"

    private var fixture: CoordinatorHarness?
    private var stubHosts: [String] = []
    private let scans = OSAllocatedUnfairLock(initialState: 0)

    override func setUp() async throws {
        try await super.setUp()
        fixture = nil
        stubHosts = []
        scans.withLock { $0 = 0 }
    }

    override func tearDown() async throws {
        stubHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// The camera presents another certificate than the pinned one. The handshake is
    /// cancelled, which a stub shows as a request that fails with `cancelled`.
    func testAChangedCertificateShowsWhatToDoWithoutConnectingRescanningOrRetrying() async throws {
        let host = "192.168.79.40"
        stub(host, ONVIFStubURLProtocol.Reply.failing(with: .cancelled))
        var info = Self.camera(at: host)
        info.useHTTPS = true
        info.pinnedCertificate = TestCertificate.otherFingerprint
        let presented = try TestCertificate.serverTrust(host: host)
        let (harness, camera) = try makeHarness(saving: info, presenting: presented)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let failed = await waitUntil(timeout: 5) { harness.status(camera) == .error }

        XCTAssertTrue(failed)
        XCTAssertEqual(
            harness.manager.errorMessages[camera],
            "The certificate of the camera at 192.168.79.40 changed. "
                + "Open the camera in Settings and click Fetch Profiles to review it."
        )
        assertWaitsForTheUser(harness)
    }

    /// Nothing at all is sent to a camera outside the local network over plain HTTP
    /// until its checkbox allows it.
    func testPlainHTTPOutsideTheLocalNetworkShowsWhatToDoAndSendsNothing() async throws {
        let host = "203.0.113.40"
        let requests = CapturedBodies()
        stubHosts.append(host)
        let reply = ONVIFResolveFixture.streamURIReply("rtsp://\(host):554/main")
        ONVIFStubURLProtocol.register(host: host) { _, body in
            requests.append(body)
            return reply
        }
        let (harness, camera) = try makeHarness(saving: Self.camera(at: host))

        harness.coordinator.previewStore.isPreviewEnabled = true
        let failed = await waitUntil(timeout: 5) { harness.status(camera) == .error }

        XCTAssertTrue(failed)
        XCTAssertEqual(
            harness.manager.errorMessages[camera],
            "203.0.113.40 is outside your local network. "
                + "Use HTTPS, or turn on Allow Unencrypted HTTP for this camera."
        )
        XCTAssertTrue(requests.all.isEmpty)
        assertWaitsForTheUser(harness)
    }

    /// With the checkbox on, the same camera connects.
    func testPlainHTTPOutsideTheLocalNetworkConnectsOnceAllowed() async throws {
        let host = "203.0.113.41"
        stub(host, ONVIFResolveFixture.streamURIReply("rtsp://\(host):554/main"))
        var info = Self.camera(at: host)
        info.allowsPlainHTTPOutsideLocalNetwork = true
        let (harness, _) = try makeHarness(saving: info)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/main"])
    }

    /// After a DHCP change another camera answers at the saved address. It is asked
    /// who it is without the login, and gets nothing more. The scan doesn't find the
    /// camera anywhere else, so it waits for the user.
    func testADifferentDeviceAtTheSavedAddressWaitsForTheUserWhenTheScanDoesNotFindTheCamera() async throws {
        let host = "192.168.79.50"
        let requests = stubCamera(at: host, identity: Self.otherDevice)
        let (harness, camera) = try makeHarness(saving: Self.camera(at: host))

        harness.coordinator.previewStore.isPreviewEnabled = true
        let failed = await waitUntil(timeout: 5) { harness.status(camera) == .error }

        XCTAssertTrue(failed)
        XCTAssertEqual(harness.manager.errorMessages[camera], "A different device answered at 192.168.79.50.")
        XCTAssertEqual(requests.all.count, 1)
        XCTAssertFalse(Self.anySigned(requests), "the login must not go to another device")
        assertWaitsForTheUser(harness, scans: 1)
        XCTAssertEqual(Self.savedHost(of: camera, in: harness), host)
    }

    /// After a DHCP swap another device took the camera's address and the camera has a
    /// new one, where the scan finds it. It streams from there with the saved login,
    /// and the move is saved only once it answered there (a scan reply can come from a
    /// device with a cloned UUID). The other device never gets the login.
    func testADifferentDeviceAtTheSavedAddressLeadsToTheCameraAtTheAddressTheScanFinds() async throws {
        let (oldHost, newHost) = ("192.168.79.52", "192.168.79.53")
        let wrongDevice = stubCamera(at: oldHost, identity: Self.otherDevice)
        let (harness, camera) = try makeHarness(
            saving: Self.camera(at: oldHost), scanFinding: [ONVIFResolveFixture.device(host: newHost)]
        )
        let sourcesFile = harness.sourcesFile
        let savedWhileAsked = OSAllocatedUnfairLock(initialState: [Bool]())
        let movedCamera = stubCamera(at: newHost, identity: ONVIFResolveFixture.deviceUUID) {
            let saved = (try? String(contentsOf: sourcesFile, encoding: .utf8))?.contains(newHost) == true
            savedWhileAsked.withLock { $0.append(saved) }
        }

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(newHost):554/main"])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [ONVIFResolveFixture.credentials])
        XCTAssertNil(harness.manager.errorMessages[camera])
        XCTAssertEqual(scans.withLock { $0 }, 1)
        XCTAssertEqual(wrongDevice.all.count, 1)
        XCTAssertFalse(Self.anySigned(wrongDevice), "the login must not go to another device")
        XCTAssertTrue(Self.anySigned(movedCamera), "the camera is asked with the saved login")
        let whileAsked = savedWhileAsked.withLock { $0 }
        XCTAssertFalse(whileAsked.isEmpty)
        XCTAssertFalse(whileAsked.contains(true), "the move is saved only once the camera answered")
        XCTAssertEqual(Self.savedHost(of: camera, in: harness), newHost)
    }

    /// The camera saved there answers: one unsigned question more, then as before.
    func testTheCameraSavedAtTheAddressConnects() async throws {
        let host = "192.168.79.51"
        let requests = stubCamera(at: host, identity: ONVIFResolveFixture.deviceUUID.uppercased())
        let (harness, camera) = try makeHarness(saving: Self.camera(at: host))

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/main"])
        XCTAssertNil(harness.manager.errorMessages[camera])
        let identityQuestions = requests.all.compactMap { String(bytes: $0, encoding: .utf8) }
            .filter { $0.contains("GetEndpointReference") }
        XCTAssertEqual(identityQuestions.count, 1)
    }

    // MARK: - Helpers

    private static let otherDevice = "5f0c1d2e-0000-4000-8000-0000000000aa"

    /// A camera at `host` whose endpoint reference is `identity` and whose stream URI
    /// is `rtsp://<host>:554/main`, and the request bodies it receives. `onRequest`
    /// runs as each request arrives.
    private func stubCamera(
        at host: String, identity: String, onRequest: @escaping @Sendable () -> Void = {}
    ) -> CapturedBodies {
        let requests = CapturedBodies()
        stubHosts.append(host)
        let endpoint = ONVIFResolveFixture.endpointReferenceReply(identity)
        let stream = ONVIFResolveFixture.streamURIReply("rtsp://\(host):554/main")
        ONVIFStubURLProtocol.register(host: host) { _, body in
            onRequest()
            requests.append(body)
            let isIdentityQuestion = String(bytes: body, encoding: .utf8)?.contains("GetEndpointReference") == true
            return isIdentityQuestion ? endpoint : stream
        }
        return requests
    }

    /// Nothing connected, no retry scheduled, and `scans` scans run: none, unless the
    /// camera was looked for.
    private func assertWaitsForTheUser(
        _ harness: CoordinatorHarness, scans expected: Int = 0, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty, "nothing may connect", file: file, line: line)
        XCTAssertEqual(scans.withLock { $0 }, expected, "scans", file: file, line: line)
        XCTAssertFalse(harness.coordinator.hasPendingRetry, "no retry", file: file, line: line)
        XCTAssertEqual(harness.coordinator.placeholderMessage, "Connection error in LemurCam", file: file, line: line)
    }

    /// Whether any request carried the WS-Security login.
    private static func anySigned(_ requests: CapturedBodies) -> Bool {
        requests.all.contains { String(bytes: $0, encoding: .utf8)?.contains("UsernameToken") == true }
    }

    private static func savedHost(of camera: UUID, in harness: CoordinatorHarness) -> String? {
        guard case .onvif(let info)? = harness.manager.sources.first(where: { $0.id == camera })?.sourceType else {
            return nil
        }
        return info.host
    }

    private static func camera(at host: String) -> ONVIFSourceInfo {
        ONVIFSourceInfo(
            deviceUUID: ONVIFResolveFixture.deviceUUID, host: host, port: 80,
            selectedProfileToken: "main", streamURI: storedURI
        )
    }

    private func stub(_ host: String, _ reply: ONVIFStubURLProtocol.Reply) {
        stubHosts.append(host)
        ONVIFStubURLProtocol.register(host: host) { _, _ in reply }
    }

    /// A coordinator with the camera `info` saved, with credentials, whose clients are
    /// made as the app makes them, and whose scans find `scanFinding`. When
    /// `presenting` is given, each client's certificate check meets that certificate
    /// first.
    private func makeHarness(
        saving info: ONVIFSourceInfo, presenting trust: SecTrust? = nil, scanFinding found: [DiscoveredDevice] = []
    ) throws -> (CoordinatorHarness, UUID) {
        let scanCounter = scans
        let presented = trust.map(SendableTrust.init)
        let harness = CoordinatorHarness(onvifEnvironment: ONVIFResolveEnvironment(
            scan: {
                scanCounter.withLock { $0 += 1 }
                return found
            },
            makeClient: { info, credentials in
                let client = StreamCoordinator.makeONVIFClient(
                    for: info, credentials: credentials, configuration: ONVIFStubURLProtocol.configuration()
                )
                if let presented { TestCertificate.present(presented.trust, to: client.serverTrust) }
                return client
            }
        ))
        fixture = harness
        try harness.manager.addSource(
            name: "Porch", sourceType: .onvif(info), credentials: ONVIFResolveFixture.credentials
        )
        return (harness, try XCTUnwrap(harness.manager.sources.last?.id))
    }
}
