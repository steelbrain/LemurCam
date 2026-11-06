@testable import LemurCam
import XCTest

/// `ONVIFXML.parse` is the guard in front of XMLKit's recursive tree builder. A few
/// KB of nested tags used to overflow the stack (SIGBUS) when they arrived in a
/// WS-Discovery reply or a camera's HTTP response. These tests feed such documents
/// through every network-facing parser and require a clean rejection, and pin that
/// ordinary SOAP documents still parse.
internal final class ONVIFXMLTests: XCTestCase {
    private func nested(_ depth: Int, name: String = "a") -> String {
        String(repeating: "<\(name)>", count: depth) + String(repeating: "</\(name)>", count: depth)
    }

    private func soapEnvelope(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Header/>
          <s:Body>\(body)</s:Body>
        </s:Envelope>
        """
    }

    // MARK: - Depth limit

    /// Thousands of nested elements (far past the ~650 that crashed) are rejected
    /// before XMLKit recurses, instead of crashing the process.
    func testDeeplyNestedDocumentIsRejected() {
        XCTAssertThrowsError(try ONVIFXML.parse(Data(nested(20_000).utf8))) { error in
            XCTAssertEqual(error as? ONVIFXML.Rejection, .tooDeep)
        }
    }

    func testDepthAtLimitParsesAndOneDeeperIsRejected() throws {
        let limit = ONVIFXML.maxElementDepth
        let root = try ONVIFXML.parse(nested(limit))
        XCTAssertEqual(root.name, "a")
        XCTAssertThrowsError(try ONVIFXML.parse(nested(limit + 1))) { error in
            XCTAssertEqual(error as? ONVIFXML.Rejection, .tooDeep)
        }
    }

    /// Self-closing siblings, comments and CDATA do not add depth, and a `>` inside
    /// a quoted attribute value does not end the tag early.
    func testFlatMarkupDoesNotCountAsNesting() throws {
        let siblings = String(repeating: "<e a=\"x>y\"/>", count: 500)
        let hidden = String(repeating: "<a>", count: 500)
        let xml = "<r>\(siblings)<!-- \(hidden) --><![CDATA[\(hidden)]]><?pi \(hidden)?></r>"
        let root = try ONVIFXML.parse(xml)
        XCTAssertEqual(root.elementChildren.count, 500)
    }

    /// XMLKit ignores end tags at the top level, so stray end tags must not lower
    /// the measured depth and let a deep document through.
    func testStrayEndTagsDoNotHideNesting() {
        let xml = String(repeating: "</x>", count: 1000) + nested(1000)
        XCTAssertThrowsError(try ONVIFXML.parse(xml)) { error in
            XCTAssertEqual(error as? ONVIFXML.Rejection, .tooDeep)
        }
    }

    /// `<` followed by a combining mark is one Character that XMLKit reads as text,
    /// not markup. A quote after it must not hide the nesting that follows from the
    /// scan, since XMLKit does not treat it as an attribute quote either.
    func testCombiningCharactersDoNotHideNesting() {
        let xml = "<r><\u{338}\"\(nested(1000))\"</r>"
        XCTAssertThrowsError(try ONVIFXML.parse(xml)) { error in
            XCTAssertEqual(error as? ONVIFXML.Rejection, .tooDeep)
        }
    }

    func testDocumentTypeDeclarationIsRejected() {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY e \"x\">]><r>&e;</r>"
        XCTAssertThrowsError(try ONVIFXML.parse(xml)) { error in
            XCTAssertEqual(error as? ONVIFXML.Rejection, .unsupportedMarkup)
        }
    }

    func testOversizedDocumentIsRejected() {
        let padding = String(repeating: " ", count: ONVIFXML.maxDocumentBytes)
        XCTAssertThrowsError(try ONVIFXML.parse(Data("<r>\(padding)</r>".utf8))) { error in
            XCTAssertEqual(error as? ONVIFXML.Rejection, .tooLarge)
        }
    }

    // MARK: - Network-facing parsers

    func testProbeMatchParserRejectsDeepReply() {
        let context = ONVIFDiscovery.ReplyContext(probeMessageID: "uuid:x", sender: "192.0.2.1")
        XCTAssertNil(ONVIFDiscovery.parseProbeMatch(xml: nested(20_000, name: "XAddrs"), context: context))
    }

    func testClientParsersRejectDeepResponses() {
        let client = ONVIFClient(host: "127.0.0.1", port: 80, username: nil, password: nil)
        let data = Data(soapEnvelope(body: nested(20_000, name: "Profiles")).utf8)
        XCTAssertThrowsError(try client.parseProfiles(data))
        XCTAssertThrowsError(try client.parseStreamURI(data))
        XCTAssertThrowsError(try client.parseDeviceInformation(data))
        XCTAssertNil(client.extractSOAPFault(from: data))
    }

    func testNormalSOAPResponseStillParses() throws {
        let client = ONVIFClient(host: "127.0.0.1", port: 80, username: nil, password: nil)
        let xml = soapEnvelope(body: """
            <GetStreamUriResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
              <MediaUri><Uri>rtsp://192.0.2.10:554/main</Uri></MediaUri>
            </GetStreamUriResponse>
            """)
        XCTAssertEqual(try client.parseStreamURI(Data(xml.utf8)), "rtsp://192.0.2.10:554/main")
    }

    // MARK: - HTTP body cap

    /// A response body over the cap is abandoned rather than buffered in full.
    func testOversizedHTTPResponseIsRejected() async {
        let stubHost = "onvif-xml-\(UUID().uuidString).invalid"
        defer { ONVIFStubURLProtocol.unregister(host: stubHost) }
        let oversized = Data(repeating: UInt8(ascii: " "), count: ONVIFXML.maxDocumentBytes + 1)
        ONVIFStubURLProtocol.register(host: stubHost) { _, _ in
            ONVIFStubURLProtocol.Reply(body: oversized)
        }
        let client = ONVIFClient(
            host: stubHost, port: 80, username: nil, password: nil,
            configuration: ONVIFStubURLProtocol.configuration()
        )
        do {
            _ = try await client.getProfiles()
            XCTFail("expected the oversized response to be rejected")
        } catch {
            XCTAssertEqual(error as? ONVIFXML.Rejection, .tooLarge)
        }
    }
}
