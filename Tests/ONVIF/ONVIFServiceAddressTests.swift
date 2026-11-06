@testable import LemurCam
import os
import XCTest
import XMLKit

/// Where requests go: the scheme the user or discovery chose (an `https` device
/// service used to be dialled as plain HTTP on port 443), and the media service path
/// the device reports in GetCapabilities instead of an assumed `/onvif/media`.
internal final class ONVIFServiceAddressTests: XCTestCase {
    private struct Sent {
        let url: URL
        let operation: String
        let signed: Bool
    }

    private final class Recorder: Sendable {
        private let sent = OSAllocatedUnfairLock<[Sent]>(initialState: [])
        var all: [Sent] { sent.withLock { $0 } }
        func record(_ entry: Sent) { sent.withLock { $0.append(entry) } }
    }

    private func envelope(_ body: String) -> Data {
        Data("""
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
                        xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body>\(body)</s:Body></s:Envelope>
            """.utf8)
    }

    private var profilesReply: Data {
        envelope("""
            <GetProfilesResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
            <Profiles token="main"><Name>Main</Name></Profiles></GetProfilesResponse>
            """)
    }

    private func capabilitiesReply(mediaXAddr: String) -> Data {
        envelope("""
            <tds:GetCapabilitiesResponse><tds:Capabilities>
            <tt:Device><tt:XAddr>http://192.0.2.7/onvif/device_service</tt:XAddr></tt:Device>
            <tt:Media><tt:XAddr>\(mediaXAddr)</tt:XAddr></tt:Media>
            </tds:Capabilities></tds:GetCapabilitiesResponse>
            """)
    }

    /// Calls getProfiles twice against a stub camera and returns every request sent.
    private func run(
        useHTTPS: Bool, port: Int, capabilities: @escaping @Sendable () -> ONVIFStubURLProtocol.Reply
    ) async throws -> [Sent] {
        let host = "onvif-address-\(UUID().uuidString).invalid"
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let recorder = Recorder()
        let profiles = profilesReply
        ONVIFStubURLProtocol.register(host: host) { request, body in
            let root = try? ONVIFXML.parse(body)
            let operation = root?["Body"]?.elementChildren.first?.name ?? "?"
            if let url = request.url {
                recorder.record(Sent(url: url, operation: operation, signed: root?["Header"]?["Security"] != nil))
            }
            return operation == "GetCapabilities" ? capabilities() : ONVIFStubURLProtocol.Reply(body: profiles)
        }
        let client = ONVIFClient(
            host: host, port: port, username: nil, password: nil, useHTTPS: useHTTPS,
            policy: .stubCamera, configuration: ONVIFStubURLProtocol.configuration()
        )
        _ = try await client.getProfiles()
        _ = try await client.getProfiles()
        return recorder.all
    }

    // MARK: - Scheme

    func testHTTPSDeviceIsDialledOverHTTPS() async throws {
        let sent = try await run(useHTTPS: true, port: 443) { ONVIFStubURLProtocol.Reply(status: 500) }
        XCTAssertFalse(sent.isEmpty)
        for request in sent {
            XCTAssertEqual(request.url.scheme, "https")
            XCTAssertEqual(request.url.port, 443)
        }
    }

    func testHTTPDeviceIsDialledOverHTTP() async throws {
        let sent = try await run(useHTTPS: false, port: 8080) { ONVIFStubURLProtocol.Reply(status: 500) }
        XCTAssertEqual(sent.first?.url.scheme, "http")
        XCTAssertEqual(sent.first?.url.port, 8080)
    }

    // MARK: - Media service path

    /// The reported path is used, but the host stays the configured one even though
    /// the device reported a different (for example internal) address.
    func testUsesReportedMediaPathOnConfiguredHost() async throws {
        let reply = capabilitiesReply(mediaXAddr: "http://10.9.8.7:8999/onvif/Media_Service")
        let sent = try await run(useHTTPS: false, port: 8080) { ONVIFStubURLProtocol.Reply(body: reply) }

        XCTAssertEqual(sent.map(\.operation), ["GetCapabilities", "GetProfiles", "GetProfiles"])
        XCTAssertEqual(sent[0].url.path, "/onvif/device_service")
        XCTAssertFalse(sent[0].signed)
        for request in sent.dropFirst() {
            XCTAssertEqual(request.url.path, "/onvif/Media_Service")
            XCTAssertNotEqual(request.url.host, "10.9.8.7")
            XCTAssertEqual(request.url.port, 8080)
        }
    }

    func testFallsBackToDefaultMediaPathWhenCapabilitiesFail() async throws {
        let sent = try await run(useHTTPS: false, port: 80) { ONVIFStubURLProtocol.Reply(status: 500) }
        XCTAssertEqual(sent.map(\.operation), ["GetCapabilities", "GetProfiles", "GetProfiles"])
        XCTAssertEqual(sent.last?.url.path, "/onvif/media")
    }

    func testServicePathExtraction() {
        XCTAssertEqual(ONVIFClient.servicePath(fromXAddr: " http://192.0.2.7:80/onvif/Media \n"), "/onvif/Media")
        XCTAssertEqual(ONVIFClient.servicePath(fromXAddr: "http://192.0.2.7/svc?x=1"), "/svc?x=1")
        XCTAssertNil(ONVIFClient.servicePath(fromXAddr: "http://192.0.2.7"))
        XCTAssertNil(ONVIFClient.servicePath(fromXAddr: "/onvif/media"))
        XCTAssertNil(ONVIFClient.servicePath(fromXAddr: "not a url"))
    }

    func testParseMediaServicePathIgnoresResponseWithoutMedia() {
        XCTAssertNil(ONVIFClient.parseMediaServicePath(envelope("<tds:GetCapabilitiesResponse/>")))
    }

    // MARK: - Discovery

    func testDiscoveredHTTPSDeviceKeepsItsScheme() throws {
        let xml = """
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
              <s:Header><wsa:RelatesTo>uuid:probe-1</wsa:RelatesTo></s:Header>
              <s:Body><d:ProbeMatches><d:ProbeMatch>
                <wsa:EndpointReference><wsa:Address>urn:uuid:https-cam</wsa:Address></wsa:EndpointReference>
                <d:XAddrs>https://192.0.2.7/onvif/device_service</d:XAddrs>
              </d:ProbeMatch></d:ProbeMatches></s:Body>
            </s:Envelope>
            """
        let context = ONVIFDiscovery.ReplyContext(probeMessageID: "uuid:probe-1", sender: "192.0.2.7")
        let device = try XCTUnwrap(ONVIFDiscovery.parseProbeMatch(xml: xml, context: context))
        XCTAssertTrue(device.useHTTPS)
        XCTAssertEqual(device.port, 443)
    }
}
