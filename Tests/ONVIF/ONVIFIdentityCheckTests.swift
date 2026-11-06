@testable import LemurCam
import XCTest

/// When a camera's saved address answers, nothing checked that it was still the same
/// device: after a DHCP change another camera could take the address, and LemurCam
/// streamed the wrong camera and sent it the saved login. The device is now asked
/// for its endpoint reference, unsigned, and compared with the saved identity like
/// with like; anything that can't be compared is let through, since a false mismatch
/// would stop a camera that works. Cameras are stubbed; nothing goes on the network.
internal final class ONVIFIdentityCheckTests: XCTestCase {
    private typealias Identity = ONVIFDeviceIdentity

    private static let saved = "2b9c0b1e-0000-4000-8000-00000000c0de"
    private static let other = "5f0c1d2e-0000-4000-8000-0000000000aa"

    // MARK: - Comparing

    func testTheSameUUIDMatchesWhateverItsCaseOrPrefix() {
        for reported in [Self.saved, Self.saved.uppercased(), "urn:uuid:\(Self.saved)", " uuid:\(Self.saved) "] {
            XCTAssertEqual(compare(savedUUID: Self.saved, reported: reported), .same, reported)
        }
        XCTAssertEqual(compare(savedUUID: "URN:UUID:\(Self.saved.uppercased())", reported: Self.saved), .same)
    }

    func testAnotherUUIDIsADifferentDevice() {
        XCTAssertEqual(compare(savedUUID: Self.saved, reported: "urn:uuid:\(Self.other)"), .different)
    }

    func testNothingSavedIsNotCompared() {
        XCTAssertEqual(compare(savedUUID: nil, reported: Self.other), .notCompared(.noSavedIdentity))
        XCTAssertEqual(compare(savedUUID: " ", reported: Self.other), .notCompared(.noSavedIdentity))
    }

    func testNothingReportedIsNotCompared() {
        XCTAssertEqual(compare(savedUUID: Self.saved, reported: nil), .notCompared(.noReportedIdentity))
        XCTAssertEqual(compare(savedUUID: Self.saved, reported: "urn:uuid:"), .notCompared(.noReportedIdentity))
    }

    /// Before 1.6 the form stored the serial number as the device UUID. It is no
    /// endpoint address, whatever it looks like, so it isn't compared with one.
    func testASerialNumberSavedAsTheDeviceUUIDIsNotCompared() {
        XCTAssertEqual(
            compare(savedUUID: "SN-123", reported: Self.other, savedSerial: "SN-123"),
            .notCompared(.savedIdentityIsSerialNumber)
        )
        XCTAssertEqual(
            compare(savedUUID: Self.saved, reported: Self.other, savedSerial: Self.saved.uppercased()),
            .notCompared(.savedIdentityIsSerialNumber)
        )
        // What the form also knows: the serial number the device reports.
        XCTAssertEqual(
            Identity.compare(
                savedUUID: "SN-123", savedSerialNumber: nil,
                reportedEndpointReference: Self.other, reportedSerialNumber: "SN-123"
            ),
            .notCompared(.savedIdentityIsSerialNumber)
        )
        // Saved before the serial number had a field: it may be one.
        XCTAssertEqual(
            compare(savedUUID: "SN-123", reported: "SN-456"), .notCompared(.savedIdentityIsSerialNumber)
        )
    }

    func testAUUIDIsNotComparedWithSomethingElse() {
        XCTAssertEqual(compare(savedUUID: Self.saved, reported: "device-7"), .notCompared(.differentKinds))
        XCTAssertEqual(
            compare(savedUUID: "device-7", reported: Self.other, savedSerial: "SN-1"), .notCompared(.differentKinds)
        )
    }

    /// A camera saved with its serial number apart has no serial number as its device
    /// UUID, so an endpoint address that is no UUID is compared as text.
    func testOtherEndpointAddressesAreComparedAsTextWhenTheSerialNumberIsSavedApart() {
        XCTAssertEqual(compare(savedUUID: "device-7", reported: "urn:uuid:DEVICE-7", savedSerial: "SN-1"), .same)
        XCTAssertEqual(compare(savedUUID: "device-7", reported: "device-8", savedSerial: "SN-1"), .different)
    }

    func testOnlyACameraWithAComparableIdentityIsAsked() {
        XCTAssertTrue(Identity.canCompare(ONVIFSourceInfo(deviceUUID: Self.saved, host: "h")))
        XCTAssertTrue(Identity.canCompare(ONVIFSourceInfo(deviceUUID: "device-7", host: "h", serialNumber: "SN-1")))
        XCTAssertFalse(Identity.canCompare(ONVIFSourceInfo(deviceUUID: nil, host: "h")))
        XCTAssertFalse(Identity.canCompare(ONVIFSourceInfo(deviceUUID: "SN-1", host: "h", serialNumber: "SN-1")))
        XCTAssertFalse(Identity.canCompare(ONVIFSourceInfo(deviceUUID: "SN-1", host: "h")))
    }

    func testTheStatusMessage() {
        let error = ONVIFError.differentDevice(host: "192.168.1.20")
        XCTAssertEqual(error.localizedDescription, "A different device answered at 192.168.1.20.")
        XCTAssertTrue(error.needsUserDecision)
        XCTAssertFalse(StreamCoordinator.mayFallBackToStoredURI(after: error))
        // The camera is looked for, as after a refused login, and a move found is saved
        // only once it answered there.
        let savedCamera = ONVIFSourceInfo(deviceUUID: Self.saved, host: "192.168.1.20")
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: error, at: savedCamera))
        XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: error, at: ONVIFSourceInfo(host: "192.168.1.20")))
        XCTAssertTrue(ONVIFRediscovery.savesMoveOnlyOnceAnswered(after: error))
    }

    // MARK: - Asking the device

    func testADifferentDeviceIsCaughtWithOneUnsignedRequest() async throws {
        let (client, requests) = stubbedClient { _ in ONVIFResolveFixture.endpointReferenceReply(Self.other) }

        do {
            try await client.checkIdentity(of: Self.camera)
            XCTFail("expected a different device")
        } catch ONVIFError.differentDevice(let host) {
            XCTAssertEqual(host, Self.camera.host)
        }
        XCTAssertEqual(requests.all.count, 1)
        let body = try XCTUnwrap(String(bytes: try XCTUnwrap(requests.all.first), encoding: .utf8))
        XCTAssertTrue(body.contains("GetEndpointReference"))
        XCTAssertFalse(body.contains("UsernameToken"), "the login must not go to an unchecked device")
        XCTAssertFalse(body.contains("viewer"))
    }

    func testTheSameDevicePasses() async throws {
        let reply = ONVIFResolveFixture.endpointReferenceReply(Self.saved.uppercased())
        let (client, requests) = stubbedClient { _ in reply }
        try await client.checkIdentity(of: Self.camera)
        XCTAssertEqual(requests.all.count, 1)
    }

    /// Not every camera answers GetEndpointReference without a login, or at all.
    func testAnAnswerWithoutAnIdentityLetsTheCameraThrough() async throws {
        let replies: [ONVIFStubURLProtocol.Reply] = [
            ONVIFStubURLProtocol.Reply(status: 401),
            ONVIFStubURLProtocol.Reply(status: 500, body: Data(Self.fault.utf8)),
            ONVIFStubURLProtocol.Reply(body: Data(Self.fault.utf8)),
            ONVIFStubURLProtocol.Reply(status: 404),
            ONVIFResolveFixture.streamURIReply("rtsp://192.0.2.5/s")
        ]
        for reply in replies {
            let (client, _) = stubbedClient { _ in reply }
            try await client.checkIdentity(of: Self.camera)
        }
    }

    func testANetworkFailureIsThrownAsTheRequestWouldBe() async throws {
        let (client, _) = stubbedClient { _ in .failing(with: .cannotConnectToHost) }
        do {
            try await client.checkIdentity(of: Self.camera)
            XCTFail("expected the network error")
        } catch let error as ONVIFError {
            XCTAssertTrue(error.isHostUnreachable)
        }
    }

    func testACameraWithoutAComparableIdentityIsNotAsked() async throws {
        let (client, requests) = stubbedClient { _ in ONVIFResolveFixture.endpointReferenceReply(Self.other) }
        try await client.checkIdentity(of: ONVIFSourceInfo(deviceUUID: nil, host: Self.camera.host))
        try await client.checkIdentity(of: ONVIFSourceInfo(deviceUUID: "SN-1", host: Self.camera.host))
        XCTAssertTrue(requests.all.isEmpty)
    }

    // MARK: - The edit form

    /// Fetch Profiles in the edit form compares the device with the camera its details
    /// name, or with the camera as saved once an address edit cleared them.
    func testTheEditFormComparesWithTheCameraItEdits() {
        let savedCamera = ONVIFSourceInfo(deviceUUID: Self.saved, host: "192.168.79.60", serialNumber: "SN-1")
        let loaded = SourceFormONVIFDetails(saved: SourceFormONVIFAddressEdits.SavedDetails(savedCamera))
        let otherDevice = Self.details(endpoint: Self.other, serial: "SN-2")
        let sameDevice = Self.details(endpoint: Self.saved, serial: "SN-1")

        XCTAssertEqual(loaded.identity(of: otherDevice, saved: savedCamera), .different)
        XCTAssertEqual(loaded.identity(of: sameDevice, saved: savedCamera), .same)
        XCTAssertEqual(SourceFormONVIFDetails().identity(of: otherDevice, saved: savedCamera), .different)
        // A serial number an older version saved as the device UUID: the same camera.
        let legacy = ONVIFSourceInfo(deviceUUID: "SN-1", host: "192.168.79.60")
        XCTAssertEqual(
            SourceFormONVIFDetails().identity(of: sameDevice, saved: legacy), .notCompared(.savedIdentityIsSerialNumber)
        )
    }

    /// Use takes the device's identity whole: the old camera's serial number doesn't stay.
    func testUsingAnotherDeviceTakesItsIdentity() {
        let savedCamera = ONVIFSourceInfo(deviceUUID: Self.saved, host: "192.168.79.60", serialNumber: "SN-1")
        var details = SourceFormONVIFDetails(saved: SourceFormONVIFAddressEdits.SavedDetails(savedCamera))
        details.profilesFetched(Self.details(endpoint: Self.other, serial: nil), adoptingIdentity: true)
        XCTAssertEqual(details.deviceUUID, Self.other)
        XCTAssertNil(details.serialNumber)

        // Without Use, the camera keeps the identity it has.
        var kept = SourceFormONVIFDetails(saved: SourceFormONVIFAddressEdits.SavedDetails(savedCamera))
        kept.profilesFetched(Self.details(endpoint: Self.other, serial: "SN-2"))
        XCTAssertEqual(kept.deviceUUID, Self.saved)
    }

    func testTheIdentityPromptNamesTheCameraAndTheHost() {
        let prompt = DeviceIdentityPrompt(
            cameraName: "Porch", address: .init(host: "192.168.79.60", port: 80, useHTTPS: false),
            fetched: Self.details(endpoint: Self.other, serial: nil), ticket: 1
        )
        XCTAssertEqual(prompt.title, "Use this device for Porch?")
        XCTAssertTrue(prompt.message.hasPrefix("The device at 192.168.79.60 is not the one saved as Porch."))
    }

    // MARK: - Helpers

    private static func details(endpoint: String, serial: String?) -> ONVIFDeviceDetails {
        ONVIFDeviceDetails(
            profiles: [ONVIFProfile(token: "main", name: "Main", width: nil, height: nil, codec: nil)],
            info: ONVIFDeviceInfo(
                manufacturer: nil, model: nil, firmwareVersion: nil, serialNumber: serial, hardwareId: nil
            ),
            endpointReference: endpoint
        )
    }

    private static let camera = ONVIFSourceInfo(deviceUUID: saved, host: "192.168.79.60", port: 80)

    private static let fault = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault>
        <s:Code><s:Value>s:Sender</s:Value></s:Code>
        <s:Reason><s:Text xml:lang="en">Action not supported</s:Text></s:Reason>
        </s:Fault></s:Body></s:Envelope>
        """

    private func compare(savedUUID: String?, reported: String?, savedSerial: String? = nil) -> Identity.Comparison {
        Identity.compare(savedUUID: savedUUID, savedSerialNumber: savedSerial, reportedEndpointReference: reported)
    }

    /// A client with a login for a stub camera at a host of its own that answers with
    /// `reply`, and the request bodies it receives.
    private func stubbedClient(
        _ reply: @escaping @Sendable (Data) -> ONVIFStubURLProtocol.Reply
    ) -> (ONVIFClient, CapturedBodies) {
        let host = "onvif-identity-\(UUID().uuidString).invalid"
        let requests = CapturedBodies()
        ONVIFStubURLProtocol.register(host: host) { _, body in
            requests.append(body)
            return reply(body)
        }
        addTeardownBlock { ONVIFStubURLProtocol.unregister(host: host) }
        let client = ONVIFClient(
            host: host, port: 80, username: "viewer", password: "pw",
            policy: .stubCamera, configuration: ONVIFStubURLProtocol.configuration()
        )
        return (client, requests)
    }
}
