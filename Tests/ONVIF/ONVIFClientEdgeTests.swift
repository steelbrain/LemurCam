@testable import LemurCam
import XCTest

/// Locks how the ONVIF response parsers tolerate malformed or partial SOAP from
/// real-world cameras: a profile missing its token is skipped (not fatal),
/// non-numeric resolutions degrade to nil, the first *non-empty* stream URI wins,
/// and a Fault with no Text yields nil. These guard the network-facing parsers
/// against a refactor that turns "tolerate" into "throw or trap". The parse
/// helpers are pure (no network, no shared state), exercised via `@testable`.
internal final class ONVIFClientEdgeTests: XCTestCase {
    private var client: ONVIFClient?

    override func setUp() {
        super.setUp()
        client = ONVIFClient(host: "127.0.0.1", port: 80, username: nil, password: nil)
    }

    override func tearDown() {
        client = nil
        super.tearDown()
    }

    // MARK: - parseProfiles tolerance

    /// A profile element without a token attribute is skipped while valid siblings
    /// are still returned, so one malformed entry never drops the whole list.
    func testParseProfilesSkipsEntriesMissingToken() throws {
        let parser = try XCTUnwrap(client)
        let xml = soapEnvelope(body: """
            <GetProfilesResponse>
              <Profiles><Name>NoToken</Name></Profiles>
              <Profiles token="good"><Name>Good</Name></Profiles>
            </GetProfilesResponse>
            """)

        let profiles = try parser.parseProfiles(Data(xml.utf8))
        XCTAssertEqual(profiles.map(\.token), ["good"])
    }

    /// Non-numeric or empty Width/Height degrade to nil rather than throwing or
    /// trapping; the profile is still returned with whatever codec it did parse.
    func testParseProfilesDegradesNonNumericResolutionToNil() throws {
        let parser = try XCTUnwrap(client)
        let xml = soapEnvelope(body: """
            <GetProfilesResponse>
              <Profiles token="t">
                <Name>Main</Name>
                <VideoEncoderConfiguration>
                  <Resolution><Width>wide</Width><Height></Height></Resolution>
                  <Encoding>H264</Encoding>
                </VideoEncoderConfiguration>
              </Profiles>
            </GetProfilesResponse>
            """)

        let profiles = try parser.parseProfiles(Data(xml.utf8))
        XCTAssertEqual(profiles.count, 1)
        XCTAssertNil(profiles[0].width)
        XCTAssertNil(profiles[0].height)
        XCTAssertEqual(profiles[0].codec, "H264")
    }

    // MARK: - parseStreamURI tolerance

    /// The parser returns the first NON-EMPTY <Uri>; an empty one earlier in the
    /// document is skipped rather than returned or treated as "missing".
    func testParseStreamURISkipsEmptyURIAndTakesFirstNonEmpty() throws {
        let parser = try XCTUnwrap(client)
        let xml = soapEnvelope(body: """
            <GetStreamUriResponse>
              <MediaUri><Uri></Uri></MediaUri>
              <MediaUri><Uri>rtsp://cam/stream</Uri></MediaUri>
            </GetStreamUriResponse>
            """)

        XCTAssertEqual(try parser.parseStreamURI(Data(xml.utf8)), "rtsp://cam/stream")
    }

    // MARK: - extractSOAPFault tolerance

    /// A Fault carrying a Reason but no Text yields nil (there is no reason string
    /// to surface), so callers fall back to a generic HTTP error rather than "".
    func testExtractSOAPFaultReturnsNilWhenReasonHasNoText() throws {
        let parser = try XCTUnwrap(client)
        let xml = soapEnvelope(body: """
            <s:Fault>
              <s:Code><s:Value>s:Receiver</s:Value></s:Code>
              <s:Reason/>
            </s:Fault>
            """)

        XCTAssertNil(parser.extractSOAPFault(from: Data(xml.utf8)))
    }

    // MARK: - Helpers

    private func soapEnvelope(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Header/>
          <s:Body>\(body)</s:Body>
        </s:Envelope>
        """
    }
}
