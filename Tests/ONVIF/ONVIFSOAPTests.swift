@testable import LemurCam
import XCTest
import XMLKit

/// Every SOAP request is built, written, and parsed back, and each element's
/// namespace is checked. XMLKit's writer ignores `XMLElement.namespace`, so requests
/// used to go out with unqualified bodies and an unqualified WS-Security header, which
/// standards-following cameras reject.
internal final class ONVIFSOAPTests: XCTestCase {
    private typealias Space = ONVIFSOAP.Namespace

    private let token = ONVIFSOAP.UsernameToken(
        username: "viewer", password: "pa55word",
        nonce: Data((0..<16).map { UInt8($0) }),
        created: Date(timeIntervalSince1970: 1_767_323_045) // 2026-01-02T03:04:05Z
    )

    private func reparse(_ body: XMLKit.XMLElement, security: ONVIFSOAP.UsernameToken?) throws -> XMLKit.XMLElement {
        let xml = ONVIFSOAP.envelope(body: body, security: security)
        XCTAssertFalse(xml.contains("=\"\""), "writer emitted an empty namespace declaration: \(xml)")
        return try ONVIFXML.parse(xml)
    }

    private func child(_ parent: XMLKit.XMLElement?, _ name: String) throws -> XMLKit.XMLElement {
        try XCTUnwrap(parent?[name], "missing <\(name)>")
    }

    private func body(of envelope: XMLKit.XMLElement) throws -> XMLKit.XMLElement {
        XCTAssertEqual(envelope.name, "Envelope")
        XCTAssertEqual(envelope.namespace, Space.soap)
        let body = try child(envelope, "Body")
        XCTAssertEqual(body.namespace, Space.soap)
        return try XCTUnwrap(body.elementChildren.first)
    }

    // MARK: - Bodies

    func testGetProfilesIsInMediaNamespace() throws {
        let request = try body(of: reparse(ONVIFSOAP.getProfiles(), security: nil))
        XCTAssertEqual(request.name, "GetProfiles")
        XCTAssertEqual(request.namespace, Space.media)
    }

    func testGetDeviceInformationIsInDeviceNamespace() throws {
        let request = try body(of: reparse(ONVIFSOAP.getDeviceInformation(), security: nil))
        XCTAssertEqual(request.name, "GetDeviceInformation")
        XCTAssertEqual(request.namespace, Space.device)
    }

    func testGetStreamURIQualifiesEveryElement() throws {
        let request = try body(of: reparse(ONVIFSOAP.getStreamURI(profileToken: "main"), security: nil))
        XCTAssertEqual(request.name, "GetStreamUri")
        XCTAssertEqual(request.namespace, Space.media)

        let setup = try child(request, "StreamSetup")
        XCTAssertEqual(setup.namespace, Space.media)
        let stream = try child(setup, "Stream")
        XCTAssertEqual(stream.namespace, Space.schema)
        XCTAssertEqual(stream.getText(), "RTP-Unicast")
        let transport = try child(setup, "Transport")
        XCTAssertEqual(transport.namespace, Space.schema)
        let proto = try child(transport, "Protocol")
        XCTAssertEqual(proto.namespace, Space.schema)
        XCTAssertEqual(proto.getText(), "RTSP")

        let profileToken = try child(request, "ProfileToken")
        XCTAssertEqual(profileToken.namespace, Space.media)
        XCTAssertEqual(profileToken.getText(), "main")
    }

    // MARK: - WS-Security header

    func testSecurityHeaderIsQualifiedAndCarriesDigest() throws {
        let envelope = try reparse(ONVIFSOAP.getProfiles(), security: token)
        let header = try child(envelope, "Header")
        XCTAssertEqual(header.namespace, Space.soap)

        let security = try child(header, "Security")
        XCTAssertEqual(security.namespace, Space.wsse)
        XCTAssertEqual(security.attributes["mustUnderstand"], "true")
        let usernameToken = try child(security, "UsernameToken")
        XCTAssertEqual(usernameToken.namespace, Space.wsse)

        let username = try child(usernameToken, "Username")
        XCTAssertEqual(username.namespace, Space.wsse)
        XCTAssertEqual(username.getText(), "viewer")
        let password = try child(usernameToken, "Password")
        XCTAssertEqual(password.namespace, Space.wsse)
        // Base64(SHA1(nonce + "2026-01-02T03:04:05Z" + "pa55word")), computed independently.
        XCTAssertEqual(password.getText(), "pmUf/mN0JOXBuFong9JXONST/1o=")
        XCTAssertEqual(password.attributes["Type"]?.hasSuffix("#PasswordDigest"), true)
        let nonce = try child(usernameToken, "Nonce")
        XCTAssertEqual(nonce.namespace, Space.wsse)
        XCTAssertEqual(nonce.getText(), "AAECAwQFBgcICQoLDA0ODw==")
        let created = try child(usernameToken, "Created")
        XCTAssertEqual(created.namespace, Space.wsu)
        XCTAssertEqual(created.getText(), "2026-01-02T03:04:05Z")
    }

    func testPasswordIsNeverSentInClearText() {
        let xml = ONVIFSOAP.envelope(body: ONVIFSOAP.getProfiles(), security: token)
        XCTAssertFalse(xml.contains("pa55word"))
    }

    func testClientOmitsSecurityHeaderWithoutCredentials() throws {
        let client = ONVIFClient(host: "192.0.2.1", port: 80, username: nil, password: nil)
        let envelope = try ONVIFXML.parse(client.requestEnvelope(body: ONVIFSOAP.getProfiles()))
        XCTAssertEqual(try child(envelope, "Header").elementChildren.count, 0)
    }

    func testClientSignsRequestsWithCredentials() throws {
        let client = ONVIFClient(host: "192.0.2.1", port: 80, username: "viewer", password: "pa55word")
        let envelope = try ONVIFXML.parse(client.requestEnvelope(body: ONVIFSOAP.getProfiles()))
        let security = try child(child(envelope, "Header"), "Security")
        XCTAssertEqual(security.namespace, Space.wsse)
    }

    // MARK: - Wire format

    /// The body that actually leaves the client for GetStreamUri is the qualified one.
    func testGetStreamURISendsQualifiedBody() async throws {
        let host = "onvif-soap-\(UUID().uuidString).invalid"
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let captured = CapturedBodies()
        ONVIFStubURLProtocol.register(host: host) { _, body in
            captured.append(body)
            let reply = """
                <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>
                <GetStreamUriResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
                <MediaUri><Uri>rtsp://192.0.2.1/main</Uri></MediaUri></GetStreamUriResponse>
                </s:Body></s:Envelope>
                """
            return ONVIFStubURLProtocol.Reply(body: Data(reply.utf8))
        }
        let client = ONVIFClient(
            host: host, port: 80, username: nil, password: nil,
            policy: .stubCamera, configuration: ONVIFStubURLProtocol.configuration()
        )

        let uri = try await client.getStreamURI(profileToken: "main")

        XCTAssertEqual(uri, "rtsp://192.0.2.1/main")
        let sent = try XCTUnwrap(captured.all.last)
        let request = try body(of: ONVIFXML.parse(sent))
        XCTAssertEqual(request.name, "GetStreamUri")
        XCTAssertEqual(request.namespace, Space.media)
    }
}
