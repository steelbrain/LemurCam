@testable import LemurCam
import XCTest

/// `deviceUUID` must hold the WS-Discovery endpoint UUID, or rediscovery can never
/// match the camera. The add/edit form used to store the serial number there, so
/// manually added cameras were never rediscovered, and "Fetch Profiles" on a
/// discovered camera replaced its real UUID with the serial. The serial now has its
/// own field, and the endpoint UUID comes from GetEndpointReference.
internal final class ONVIFDeviceIdentityTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        return jsonDecoder
    }()

    // MARK: - Choosing the device UUID

    func testDiscoveredUUIDSurvivesFetchingDetails() {
        XCTAssertEqual(
            ONVIFSourceInfo.resolvedDeviceUUID(
                current: "real-endpoint-uuid", serialNumber: "SN-123", endpointReference: "other"
            ),
            "real-endpoint-uuid"
        )
    }

    func testManualCameraTakesEndpointReference() {
        XCTAssertEqual(
            ONVIFSourceInfo.resolvedDeviceUUID(current: nil, serialNumber: "SN-123", endpointReference: "ep-uuid"),
            "ep-uuid"
        )
        XCTAssertNil(ONVIFSourceInfo.resolvedDeviceUUID(current: "", serialNumber: nil, endpointReference: nil))
    }

    /// A serial left in `deviceUUID` by an older version is replaced when the device
    /// reports its endpoint UUID, and otherwise left as it was.
    func testLegacySerialInDeviceUUIDIsRepaired() {
        XCTAssertEqual(
            ONVIFSourceInfo.resolvedDeviceUUID(current: "SN-123", serialNumber: "SN-123", endpointReference: "ep-uuid"),
            "ep-uuid"
        )
        XCTAssertEqual(
            ONVIFSourceInfo.resolvedDeviceUUID(current: "SN-123", serialNumber: "SN-123", endpointReference: nil),
            "SN-123"
        )
    }

    // MARK: - GetEndpointReference

    func testParsesEndpointReference() {
        let xml = """
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                        xmlns:tds="http://www.onvif.org/ver10/device/wsdl"><s:Body>
            <tds:GetEndpointReferenceResponse>
              <tds:GUID> urn:uuid:5f0c1d2e-0000-4000-8000-0000000000aa </tds:GUID>
            </tds:GetEndpointReferenceResponse></s:Body></s:Envelope>
            """
        XCTAssertEqual(ONVIFClient.parseEndpointReference(Data(xml.utf8)), "5f0c1d2e-0000-4000-8000-0000000000aa")
    }

    func testEndpointReferenceMissing() {
        let xml = "<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\"><s:Body/></s:Envelope>"
        XCTAssertNil(ONVIFClient.parseEndpointReference(Data(xml.utf8)))
    }

    func testGetEndpointReferenceIsInDeviceNamespace() throws {
        let envelope = try ONVIFXML.parse(ONVIFSOAP.envelope(body: ONVIFSOAP.getEndpointReference(), security: nil))
        let request = try XCTUnwrap(envelope["Body"]?.elementChildren.first)
        XCTAssertEqual(request.name, "GetEndpointReference")
        XCTAssertEqual(request.namespace, ONVIFSOAP.Namespace.device)
    }

    // MARK: - Persistence

    func testOldSourceWithoutSerialNumberDecodes() throws {
        let json = """
            {"id": "33333333-3333-3333-3333-333333333333", "name": "Old",
             "createdAt": "2026-01-02T03:04:05Z", "updatedAt": "2026-01-02T03:04:05Z",
             "sourceType": {"onvif": {"_0": {"deviceUUID": "SN-123", "host": "192.0.2.4", "port": 80}}}}
            """
        let source = try decoder.decode(CameraSource.self, from: Data(json.utf8))
        guard case .onvif(let info) = source.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.deviceUUID, "SN-123")
        XCTAssertNil(info.serialNumber)
    }

    func testSerialNumberRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let source = CameraSource(name: "Cam", sourceType: .onvif(ONVIFSourceInfo(
            deviceUUID: "ep-uuid", host: "192.0.2.4", port: 80, serialNumber: "SN-123"
        )))
        let decoded = try decoder.decode(CameraSource.self, from: encoder.encode(source))
        XCTAssertEqual(decoded.sourceType, source.sourceType)
    }
}
