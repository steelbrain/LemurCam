@testable import LemurCam
import XCTest

internal final class ONVIFDiscoveryTests: XCTestCase {

    // MARK: - parseProbeMatch

    func testParseValidProbeMatch() {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
              <s:Body>
                <d:ProbeMatches>
                  <d:ProbeMatch>
                    <wsa:EndpointReference>
                      <wsa:Address>urn:uuid:abcd-1234</wsa:Address>
                    </wsa:EndpointReference>
                    <d:Scopes>onvif://www.onvif.org/name/FrontDoor onvif://www.onvif.org/hardware/Acme onvif://www.onvif.org/model/X100</d:Scopes>
                    <d:XAddrs>http://192.168.1.50:8080/onvif/device_service</d:XAddrs>
                  </d:ProbeMatch>
                </d:ProbeMatches>
              </s:Body>
            </s:Envelope>
            """

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)

        XCTAssertNotNil(device)
        XCTAssertEqual(device?.id, "abcd-1234")
        XCTAssertEqual(device?.host, "192.168.1.50")
        XCTAssertEqual(device?.port, 8080)
        XCTAssertEqual(device?.name, "FrontDoor")
        XCTAssertEqual(device?.manufacturer, "Acme")
        XCTAssertEqual(device?.model, "X100")
        XCTAssertEqual(device?.endpointURL, "http://192.168.1.50:8080/onvif/device_service")
    }

    func testParseProbeMatchStripsUrnUUIDPrefix() {
        let xml = probeMatchXML(
            uuid: "urn:uuid:12345678-abcd-efgh-ijkl-000000000001",
            xaddrs: "http://10.0.0.1/onvif/device_service"
        )

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)
        XCTAssertEqual(device?.id, "12345678-abcd-efgh-ijkl-000000000001")
    }

    func testParseProbeMatchDefaultsPortTo80() {
        let xml = probeMatchXML(
            uuid: "test-uuid",
            xaddrs: "http://192.168.1.10/onvif/device_service"
        )

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)
        XCTAssertEqual(device?.port, 80)
    }

    func testParseProbeMatchDefaultsHTTPSPortTo443() {
        let xml = probeMatchXML(
            uuid: "test-uuid",
            xaddrs: "https://192.168.1.10/onvif/device_service"
        )

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)
        XCTAssertEqual(device?.port, 443)
    }

    func testParseProbeMatchPicksFirstXAddrs() {
        let xml = probeMatchXML(
            uuid: "test-uuid",
            xaddrs: "http://192.168.1.10:80/onvif http://10.0.0.1:8080/onvif"
        )

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)
        XCTAssertEqual(device?.endpointURL, "http://192.168.1.10:80/onvif")
        XCTAssertEqual(device?.host, "192.168.1.10")
    }

    func testParseProbeMatchPercentDecodesName() {
        let xml = probeMatchXML(
            uuid: "test-uuid",
            xaddrs: "http://10.0.0.1/onvif/device_service",
            scopes: "onvif://www.onvif.org/name/Front%20Door"
        )

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)
        XCTAssertEqual(device?.name, "Front Door")
    }

    func testParseProbeMatchReturnsNilForMissingUUID() {
        let xml = """
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
              <s:Body>
                <d:ProbeMatches>
                  <d:ProbeMatch>
                    <d:XAddrs>http://10.0.0.1/onvif</d:XAddrs>
                  </d:ProbeMatch>
                </d:ProbeMatches>
              </s:Body>
            </s:Envelope>
            """

        XCTAssertNil(ONVIFDiscovery.parseProbeMatch(xml: xml))
    }

    func testParseProbeMatchReturnsNilForMissingXAddrs() {
        let xml = """
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">
              <s:Body>
                <wsa:EndpointReference>
                  <wsa:Address>urn:uuid:abc</wsa:Address>
                </wsa:EndpointReference>
              </s:Body>
            </s:Envelope>
            """

        XCTAssertNil(ONVIFDiscovery.parseProbeMatch(xml: xml))
    }

    func testParseProbeMatchReturnsNilForMalformedXML() {
        XCTAssertNil(ONVIFDiscovery.parseProbeMatch(xml: "not xml at all"))
    }

    func testParseProbeMatchWithManufacturerScope() {
        let xml = probeMatchXML(
            uuid: "test-uuid",
            xaddrs: "http://10.0.0.1/onvif/device_service",
            scopes: "onvif://www.onvif.org/manufacturer/Hikvision"
        )

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)
        XCTAssertEqual(device?.manufacturer, "Hikvision")
    }

    /// `manufacturer` is sourced from the `hardware` scope first, falling back to the
    /// `manufacturer` scope. When both are present, `hardware` wins — pin that
    /// precedence so a refactor swapping the `??` operands is caught.
    func testParseProbeMatchPrefersHardwareScopeOverManufacturer() {
        let xml = probeMatchXML(
            uuid: "test-uuid",
            xaddrs: "http://10.0.0.1/onvif/device_service",
            scopes: "onvif://www.onvif.org/hardware/HW-Brand onvif://www.onvif.org/manufacturer/Mfr-Brand"
        )

        let device = ONVIFDiscovery.parseProbeMatch(xml: xml)
        XCTAssertEqual(device?.manufacturer, "HW-Brand")
    }

    // MARK: - extractScope

    func testExtractScopeFindsValue() {
        let scopes = "onvif://www.onvif.org/name/Camera1 onvif://www.onvif.org/model/X200"
        XCTAssertEqual(ONVIFDiscovery.extractScope(from: scopes, key: "name"), "Camera1")
        XCTAssertEqual(ONVIFDiscovery.extractScope(from: scopes, key: "model"), "X200")
    }

    func testExtractScopeReturnsNilForMissingKey() {
        let scopes = "onvif://www.onvif.org/name/Camera1"
        XCTAssertNil(ONVIFDiscovery.extractScope(from: scopes, key: "model"))
    }

    func testExtractScopeReturnsNilForEmptyValue() {
        let scopes = "onvif://www.onvif.org/name/"
        XCTAssertNil(ONVIFDiscovery.extractScope(from: scopes, key: "name"))
    }

    func testExtractScopeReturnsNilForEmptyString() {
        XCTAssertNil(ONVIFDiscovery.extractScope(from: "", key: "name"))
    }

    // MARK: - receiveOutcome (recvfrom error handling)

    func testReceiveOutcomeProcessesPositiveLength() {
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: 512, errnoValue: 0), .process(512))
    }

    func testReceiveOutcomeRetriesEmptyDatagram() {
        // A zero-length datagram is valid; errno is irrelevant when received == 0.
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: 0, errnoValue: ECONNREFUSED), .retry)
    }

    func testReceiveOutcomeRetriesOnTimeoutAndInterrupt() {
        // SO_RCVTIMEO surfaces a no-data interval as EAGAIN after blocking, so retrying
        // it does not busy-spin. EINTR is a transient interruption.
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: -1, errnoValue: EAGAIN), .retry)
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: -1, errnoValue: EWOULDBLOCK), .retry)
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: -1, errnoValue: EINTR), .retry)
    }

    /// A hard error returns immediately (not after the receive timeout), so before the
    /// fix the loop spun a core until the scan deadline. It must back off instead.
    func testReceiveOutcomeBacksOffOnHardError() {
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: -1, errnoValue: ECONNREFUSED), .backOff)
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: -1, errnoValue: ENETUNREACH), .backOff)
    }

    func testReceiveOutcomeStopsOnUnusableSocket() {
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: -1, errnoValue: EBADF), .stop)
        XCTAssertEqual(ONVIFDiscovery.receiveOutcome(received: -1, errnoValue: ENOTSOCK), .stop)
    }

    // MARK: - Helpers

    private func probeMatchXML(uuid: String, xaddrs: String, scopes: String = "") -> String {
        """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
                    xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
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
