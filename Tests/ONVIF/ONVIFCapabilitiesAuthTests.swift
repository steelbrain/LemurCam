@testable import LemurCam
import os
import XCTest

/// GetCapabilities goes out unsigned so a wrong password costs no extra failed login.
/// A camera that refuses it without authentication (HTTP 401, or a `NotAuthorized`
/// fault) used to leave the client on the default `/onvif/media` path, which fails on
/// cameras that serve media elsewhere. With credentials it is now asked once more,
/// signed. Cameras are stubbed with `ONVIFStubURLProtocol`; nothing goes on the network.
internal final class ONVIFCapabilitiesAuthTests: XCTestCase {
    private struct Sent: Equatable {
        let operation: String
        let path: String
        let signed: Bool
    }

    private final class Recorder: Sendable {
        private let sent = OSAllocatedUnfairLock<[Sent]>(initialState: [])
        var all: [Sent] { sent.withLock { $0 } }
        func record(_ entry: Sent) { sent.withLock { $0.append(entry) } }
    }

    private static func envelope(_ body: String) -> Data {
        Data("""
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
                        xmlns:tt="http://www.onvif.org/ver10/schema"
                        xmlns:ter="http://www.onvif.org/ver10/error"><s:Body>\(body)</s:Body></s:Envelope>
            """.utf8)
    }

    private static let capabilities = envelope("""
        <tds:GetCapabilitiesResponse><tds:Capabilities>
        <tt:Media><tt:XAddr>http://192.0.2.7/onvif/Media2</tt:XAddr></tt:Media>
        </tds:Capabilities></tds:GetCapabilitiesResponse>
        """)

    private static let profiles = envelope("""
        <GetProfilesResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
        <Profiles token="main"><Name>Main</Name></Profiles></GetProfilesResponse>
        """)

    private static func fault(subcode: String?) -> Data {
        let sub = subcode.map { "<s:Subcode><s:Value>\($0)</s:Value></s:Subcode>" } ?? ""
        return envelope("""
            <s:Fault><s:Code><s:Value>s:Sender</s:Value>\(sub)</s:Code>
            <s:Reason><s:Text xml:lang="en">Sender not Authorized</s:Text></s:Reason></s:Fault>
            """)
    }

    private static let notAuthorized = ONVIFStubURLProtocol.Reply(
        status: 400, body: fault(subcode: "ter:NotAuthorized")
    )

    /// Runs getProfiles against a stub that answers unsigned GetCapabilities with
    /// `unsigned` and everything else normally; returns the requests sent.
    private func run(username: String?, unsigned: ONVIFStubURLProtocol.Reply) async throws -> [Sent] {
        let host = "onvif-capabilities-\(UUID().uuidString).invalid"
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let recorder = Recorder()
        ONVIFStubURLProtocol.register(host: host) { request, body in
            let root = try? ONVIFXML.parse(body)
            let operation = root?["Body"]?.elementChildren.first?.name ?? "?"
            let signed = root?["Header"]?["Security"] != nil
            recorder.record(Sent(operation: operation, path: request.url?.path ?? "", signed: signed))
            switch (operation, signed) {
            case ("GetCapabilities", false): return unsigned
            case ("GetCapabilities", true): return ONVIFStubURLProtocol.Reply(body: Self.capabilities)
            case ("GetSystemDateAndTime", _): return ONVIFStubURLProtocol.Reply(status: 500)
            default: return ONVIFStubURLProtocol.Reply(body: Self.profiles)
            }
        }
        let client = ONVIFClient(
            host: host, port: 80, username: username, password: username.map { _ in "pw" },
            configuration: ONVIFStubURLProtocol.configuration()
        )
        _ = try await client.getProfiles()
        return recorder.all
    }

    func testUnauthorizedStatusIsRetriedSigned() async throws {
        let sent = try await run(username: "viewer", unsigned: ONVIFStubURLProtocol.Reply(status: 401))

        XCTAssertEqual(sent, [
            Sent(operation: "GetCapabilities", path: "/onvif/device_service", signed: false),
            Sent(operation: "GetSystemDateAndTime", path: "/onvif/device_service", signed: false),
            Sent(operation: "GetCapabilities", path: "/onvif/device_service", signed: true),
            Sent(operation: "GetProfiles", path: "/onvif/Media2", signed: true)
        ])
    }

    func testNotAuthorizedFaultIsRetriedSigned() async throws {
        let sent = try await run(username: "viewer", unsigned: Self.notAuthorized)

        XCTAssertEqual(sent.filter { $0.operation == "GetCapabilities" }.map(\.signed), [false, true])
        XCTAssertEqual(sent.last, Sent(operation: "GetProfiles", path: "/onvif/Media2", signed: true))
    }

    /// Without credentials there is nothing to sign with: the default path is used.
    func testWithoutCredentialsTheDefaultPathIsUsed() async throws {
        let sent = try await run(username: nil, unsigned: ONVIFStubURLProtocol.Reply(status: 401))

        XCTAssertEqual(sent, [
            Sent(operation: "GetCapabilities", path: "/onvif/device_service", signed: false),
            Sent(operation: "GetProfiles", path: ONVIFClient.defaultMediaServicePath, signed: false)
        ])
    }

    /// Other faults are not about authentication; asking again would only add a login.
    func testOtherFaultsAreNotRetried() async throws {
        let unsupported = ONVIFStubURLProtocol.Reply(status: 400, body: Self.fault(subcode: "ter:ActionNotSupported"))
        let sent = try await run(username: "viewer", unsigned: unsupported)

        XCTAssertEqual(sent.filter { $0.operation == "GetCapabilities" }.count, 1)
        XCTAssertEqual(sent.last?.path, ONVIFClient.defaultMediaServicePath)
    }

    func testRefusalDetection() throws {
        let url = try XCTUnwrap(URL(string: "http://192.0.2.7/onvif/device_service"))
        func response(_ status: Int) throws -> URLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        }
        XCTAssertTrue(ONVIFClient.refusesUnauthenticated(Data(), response: try response(401)))
        XCTAssertTrue(ONVIFClient.refusesUnauthenticated(Self.fault(subcode: "ter:NotAuthorized"),
                                                         response: try response(400)))
        let nested = Self.envelope("""
            <s:Fault><s:Code><s:Value>s:Sender</s:Value>
            <s:Subcode><s:Value>ter:InvalidArgVal</s:Value>
            <s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Subcode></s:Code></s:Fault>
            """)
        XCTAssertTrue(ONVIFClient.refusesUnauthenticated(nested, response: try response(400)))
        XCTAssertFalse(ONVIFClient.refusesUnauthenticated(Self.fault(subcode: nil), response: try response(400)))
        XCTAssertFalse(ONVIFClient.refusesUnauthenticated(Self.capabilities, response: try response(200)))
    }
}
