import Foundation
@testable import LemurCam
import os
import Security
import XCTest

/// What connecting does when what answers at a camera's saved address needs the
/// user's decision: a certificate other than the one the user trusted, or an address
/// outside the local network that plain HTTP isn't allowed to. Trying again,
/// looking for the camera with a scan, or falling back to the stored stream URI would
/// not change the answer, and the last two may send the login to another device. The
/// camera shows what to do, and nothing connects until the camera is edited.
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

    // MARK: - Helpers

    /// Nothing connected, nothing scanned, and no retry scheduled.
    private func assertWaitsForTheUser(
        _ harness: CoordinatorHarness, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty, "nothing may connect", file: file, line: line)
        XCTAssertEqual(scans.withLock { $0 }, 0, "no scan", file: file, line: line)
        XCTAssertFalse(harness.coordinator.hasPendingRetry, "no retry", file: file, line: line)
        XCTAssertEqual(harness.coordinator.placeholderMessage, "Connection error in LemurCam", file: file, line: line)
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
    /// made as the app makes them, and whose scans find nothing. When `presenting` is
    /// given, each client's certificate check meets that certificate first.
    private func makeHarness(
        saving info: ONVIFSourceInfo, presenting trust: SecTrust? = nil
    ) throws -> (CoordinatorHarness, UUID) {
        let scanCounter = scans
        let presented = trust.map(UncheckedTrust.init)
        let harness = CoordinatorHarness(onvifEnvironment: ONVIFResolveEnvironment(
            scan: {
                scanCounter.withLock { $0 += 1 }
                return []
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

/// A `SecTrust` the stub client factory captures. It is only read.
private struct UncheckedTrust: @unchecked Sendable {
    let trust: SecTrust
}
