@testable import LemurCam
import XCTest

/// Any host on the LAN can answer the WS-Discovery multicast probe. These tests pin
/// how replies are vetted: a reply must echo the probe's MessageID in RelatesTo, and
/// the device address is always the host the reply came from, so a reply cannot
/// steer the app (and the credentials it later sends) to a third host. They also
/// pin XAddrs splitting on any whitespace.
internal final class ONVIFDiscoveryReplyTests: XCTestCase {
    private static let probeID = "uuid:6F1A2B3C-0000-4000-8000-00000000ABCD"

    private func parse(_ xml: String, sender: String) -> DiscoveredDevice? {
        ONVIFDiscovery.parseProbeMatch(
            xml: xml, context: ONVIFDiscovery.ReplyContext(probeMessageID: Self.probeID, sender: sender)
        )
    }

    /// A reply that does not answer this probe (stale, or unsolicited) is ignored.
    func testRejectsReplyRelatingToAnotherProbe() {
        let xml = probeMatchXML(
            uuid: "cam", xaddrs: "http://10.0.0.1/onvif/device_service",
            relatesTo: "uuid:00000000-0000-4000-8000-000000000000"
        )
        XCTAssertNil(parse(xml, sender: "10.0.0.1"))
    }

    func testRejectsReplyWithoutRelatesTo() {
        let xml = probeMatchXML(uuid: "cam", xaddrs: "http://10.0.0.1/onvif/device_service", relatesTo: nil)
        XCTAssertNil(parse(xml, sender: "10.0.0.1"))
    }

    func testAcceptsRelatesToWithDifferentCaseAndURNPrefix() {
        let echoed = "urn:" + Self.probeID.lowercased()
        let xml = probeMatchXML(uuid: "cam", xaddrs: "http://10.0.0.1/onvif/device_service", relatesTo: echoed)
        XCTAssertNotNil(parse(xml, sender: "10.0.0.1"))
    }

    /// A reply from one host advertising another host's address is pinned to the
    /// host it came from: the app never contacts the advertised third host.
    func testAdvertisedForeignHostIsReplacedBySender() {
        let xml = probeMatchXML(uuid: "cam", xaddrs: "http://192.168.1.77:8080/onvif/device_service")

        let device = parse(xml, sender: "192.168.1.66")

        XCTAssertEqual(device?.host, "192.168.1.66")
        XCTAssertEqual(device?.port, 8080)
        XCTAssertEqual(device?.endpointURL, "http://192.168.1.66:8080/onvif/device_service")
    }

    func testPrefersXAddrMatchingSenderOverEarlierEntries() {
        let xml = probeMatchXML(
            uuid: "cam",
            xaddrs: "http://[fe80::1234%25en0]:80/onvif http://10.1.1.1:81/onvif http://192.168.1.66:8000/onvif"
        )

        let device = parse(xml, sender: "192.168.1.66")

        XCTAssertEqual(device?.port, 8000)
        XCTAssertEqual(device?.endpointURL, "http://192.168.1.66:8000/onvif")
    }

    /// XAddrs may be separated by any whitespace, including a leading newline;
    /// splitting only on spaces used to drop such devices.
    func testSplitsXAddrsOnAnyWhitespace() {
        let xml = probeMatchXML(
            uuid: "cam",
            xaddrs: "\n\t http://10.9.9.9/a\n\thttp://192.168.1.66:8000/onvif/device_service\n"
        )

        let device = parse(xml, sender: "192.168.1.66")

        XCTAssertEqual(device?.endpointURL, "http://192.168.1.66:8000/onvif/device_service")
    }

    func testIgnoresNonHTTPXAddrs() {
        let xml = probeMatchXML(uuid: "cam", xaddrs: "soap.udp://192.168.1.66:3702 ftp://192.168.1.66/x")
        XCTAssertNil(parse(xml, sender: "192.168.1.66"))
    }

    func testNormalizesIPv4AndMappedIPv6Forms() {
        XCTAssertEqual(ONVIFDiscovery.normalizedIPAddress("192.168.1.5"), "192.168.1.5")
        XCTAssertEqual(ONVIFDiscovery.normalizedIPAddress("::ffff:192.168.1.5"), "192.168.1.5")
        XCTAssertEqual(ONVIFDiscovery.normalizedIPAddress("[::FFFF:192.168.1.5]"), "192.168.1.5")
        XCTAssertEqual(ONVIFDiscovery.normalizedIPAddress("[FE80::0001%en0]"), "fe80::1")
        XCTAssertNil(ONVIFDiscovery.normalizedIPAddress("camera.local"))
    }

    func testMappedIPv6XAddrMatchesIPv4Sender() {
        let xml = probeMatchXML(
            uuid: "cam", xaddrs: "http://10.1.1.1:81/onvif http://[::ffff:192.168.1.66]:8000/onvif"
        )
        XCTAssertEqual(parse(xml, sender: "192.168.1.66")?.port, 8000)
    }

    // MARK: - Helpers

    private func probeMatchXML(
        uuid: String, xaddrs: String, scopes: String = "", relatesTo: String? = probeID
    ) -> String {
        let header = relatesTo.map { "<s:Header><wsa:RelatesTo>\($0)</wsa:RelatesTo></s:Header>" } ?? ""
        return """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                    xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          \(header)
          <s:Body>
            <d:ProbeMatches>
              <d:ProbeMatch>
                <wsa:EndpointReference>
                  <wsa:Address>\(uuid)</wsa:Address>
                </wsa:EndpointReference>
                <d:Scopes>\(scopes)</d:Scopes>
                <d:XAddrs>\(xaddrs)</d:XAddrs>
              </d:ProbeMatch>
            </d:ProbeMatches>
          </s:Body>
        </s:Envelope>
        """
    }
}
