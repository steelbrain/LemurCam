@testable import LemurCam
import os
import XCTest

/// Locks how many logins the add/edit form's and the Discover sheet's profile fetch
/// costs. GetProfiles and GetDeviceInformation went out together, so a wrong
/// password was two failed WS-Security logins per fetch, which counts double toward
/// the lockout some cameras impose. GetProfiles now goes first, and nothing more is
/// signed unless it succeeded. Cameras are stubbed with `ONVIFStubURLProtocol`;
/// nothing goes on the network.
internal final class ONVIFDeviceDetailsFetchTests: XCTestCase {
    private final class Recorder: Sendable {
        private let sent = OSAllocatedUnfairLock<[(operation: String, signed: Bool)]>(initialState: [])
        var operations: [String] { sent.withLock { $0.map(\.operation) } }
        var signedOperations: [String] { sent.withLock { $0.filter(\.signed).map(\.operation) } }
        func record(_ operation: String, signed: Bool) { sent.withLock { $0.append((operation, signed)) } }
    }

    private static func envelope(_ body: String) -> Data {
        Data("""
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
                        xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>\(body)</s:Body></s:Envelope>
            """.utf8)
    }

    private static let capabilities = envelope("""
        <tds:GetCapabilitiesResponse><tds:Capabilities>
        <tt:Media><tt:XAddr>http://192.0.2.7/onvif/media</tt:XAddr></tt:Media>
        </tds:Capabilities></tds:GetCapabilitiesResponse>
        """)

    private static let profiles = envelope("""
        <GetProfilesResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
        <Profiles token="main"><Name>Main</Name></Profiles></GetProfilesResponse>
        """)

    private static let deviceInformation = envelope("""
        <tds:GetDeviceInformationResponse><tds:Manufacturer>Example</tds:Manufacturer>
        <tds:SerialNumber>SN-TEST-1</tds:SerialNumber></tds:GetDeviceInformationResponse>
        """)

    private static let endpointReference = envelope("""
        <tds:GetEndpointReferenceResponse><tds:GUID>urn:uuid:test-endpoint</tds:GUID>
        </tds:GetEndpointReferenceResponse>
        """)

    /// How a working camera answers `operation`. It keeps no usable clock.
    private static func answer(to operation: String) -> ONVIFStubURLProtocol.Reply {
        switch operation {
        case "GetCapabilities": return ONVIFStubURLProtocol.Reply(body: capabilities)
        case "GetSystemDateAndTime": return ONVIFStubURLProtocol.Reply(status: 500)
        case "GetDeviceInformation": return ONVIFStubURLProtocol.Reply(body: deviceInformation)
        case "GetEndpointReference": return ONVIFStubURLProtocol.Reply(body: endpointReference)
        default: return ONVIFStubURLProtocol.Reply(body: profiles)
        }
    }

    /// Runs the fetch against a stub camera. `refusesSigned` answers every signed
    /// request with HTTP 401, as for a wrong password; `capabilitiesNeedLogin` also
    /// refuses the unsigned GetCapabilities, so the client asks for it signed;
    /// `failing` operations get an HTTP 500. Returns what was sent and the result.
    private func fetch(
        refusesSigned: Bool = false,
        capabilitiesNeedLogin: Bool = false,
        failing: Set<String> = [],
        includingEndpointReference: Bool = true
    ) async -> (recorder: Recorder, result: Result<ONVIFDeviceDetails, any Error>) {
        let host = "onvif-details-\(UUID().uuidString).invalid"
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let recorder = Recorder()
        ONVIFStubURLProtocol.register(host: host) { _, body in
            let root = try? ONVIFXML.parse(body)
            let operation = root?["Body"]?.elementChildren.first?.name ?? "?"
            let signed = root?["Header"]?["Security"] != nil
            recorder.record(operation, signed: signed)
            if signed, refusesSigned { return ONVIFStubURLProtocol.Reply(status: 401) }
            if failing.contains(operation) { return ONVIFStubURLProtocol.Reply(status: 500) }
            if operation == "GetCapabilities", capabilitiesNeedLogin, !signed {
                return ONVIFStubURLProtocol.Reply(status: 401)
            }
            return Self.answer(to: operation)
        }
        let client = ONVIFClient(
            host: host, port: 80, username: "viewer", password: "pw",
            policy: .stubCamera, configuration: ONVIFStubURLProtocol.configuration()
        )
        do {
            let details = try await client.fetchDeviceDetails(includingEndpointReference: includingEndpointReference)
            return (recorder, .success(details))
        } catch {
            return (recorder, .failure(error))
        }
    }

    func testAWrongPasswordCostsOneFailedLogin() async {
        let (recorder, result) = await fetch(refusesSigned: true)

        XCTAssertEqual(recorder.signedOperations, ["GetProfiles"])
        assertAuthenticationFailed(result)
    }

    /// A camera that answers GetCapabilities only signed: the refused signed
    /// GetCapabilities is the one failed login.
    func testAWrongPasswordCostsOneFailedLoginWhenCapabilitiesNeedOne() async {
        let (recorder, result) = await fetch(refusesSigned: true, capabilitiesNeedLogin: true)

        XCTAssertEqual(recorder.signedOperations, ["GetCapabilities"])
        assertAuthenticationFailed(result)
    }

    func testDetailsAreAskedForOneAfterAnotherOnceTheProfilesCame() async throws {
        let (recorder, result) = await fetch()

        let details = try result.get()
        XCTAssertEqual(recorder.signedOperations, ["GetProfiles", "GetDeviceInformation", "GetEndpointReference"])
        XCTAssertEqual(details.profiles.map(\.token), ["main"])
        XCTAssertEqual(details.info?.serialNumber, "SN-TEST-1")
        XCTAssertEqual(details.endpointReference, "test-endpoint")
    }

    /// The Discover sheet has the endpoint UUID from the scan and does not ask.
    func testTheEndpointReferenceIsAskedForOnlyWhenWanted() async throws {
        let (recorder, result) = await fetch(includingEndpointReference: false)

        XCTAssertNil(try result.get().endpointReference)
        XCTAssertEqual(recorder.signedOperations, ["GetProfiles", "GetDeviceInformation"])
    }

    /// Not every camera supports the later requests; the profiles still come back.
    func testUnansweredDetailsDoNotFailTheFetch() async throws {
        let (_, result) = await fetch(failing: ["GetDeviceInformation", "GetEndpointReference"])

        let details = try result.get()
        XCTAssertEqual(details.profiles.map(\.token), ["main"])
        XCTAssertNil(details.info)
        XCTAssertNil(details.endpointReference)
    }

    func testNothingMoreIsAskedWhenTheProfilesFail() async {
        let (recorder, result) = await fetch(failing: ["GetProfiles"])

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(recorder.operations.last, "GetProfiles")
        XCTAssertEqual(recorder.signedOperations, ["GetProfiles"])
    }

    private func assertAuthenticationFailed(
        _ result: Result<ONVIFDeviceDetails, any Error>, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(ONVIFError.authenticationFailed) = result else {
            XCTFail("expected authenticationFailed, got \(result)", file: file, line: line)
            return
        }
    }
}
