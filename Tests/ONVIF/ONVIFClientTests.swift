@testable import LemurCam
import XCTest

internal final class ONVIFClientTests: XCTestCase {
    private var client: ONVIFClient?

    override func setUp() {
        super.setUp()
        client = ONVIFClient(host: "127.0.0.1", port: 80, username: nil, password: nil)
    }

    override func tearDown() {
        client = nil
        super.tearDown()
    }

    // MARK: - parseProfiles

    func testParseProfilesBasic() throws {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <GetProfilesResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
              <trt:Profiles token="profile_1" xmlns:trt="http://www.onvif.org/ver10/media/wsdl">
                <tt:Name xmlns:tt="http://www.onvif.org/ver10/schema">Main Stream</tt:Name>
                <tt:VideoEncoderConfiguration xmlns:tt="http://www.onvif.org/ver10/schema">
                  <tt:Resolution>
                    <tt:Width>1920</tt:Width>
                    <tt:Height>1080</tt:Height>
                  </tt:Resolution>
                  <tt:Encoding>H264</tt:Encoding>
                </tt:VideoEncoderConfiguration>
              </trt:Profiles>
            </GetProfilesResponse>
            """)

        let profiles = try client.parseProfiles(Data(xml.utf8))

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].token, "profile_1")
        XCTAssertEqual(profiles[0].name, "Main Stream")
        XCTAssertEqual(profiles[0].width, 1920)
        XCTAssertEqual(profiles[0].height, 1080)
        XCTAssertEqual(profiles[0].codec, "H264")
    }

    func testParseMultipleProfiles() throws {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <GetProfilesResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
              <Profiles token="main">
                <Name>Main</Name>
                <VideoEncoderConfiguration>
                  <Resolution><Width>1920</Width><Height>1080</Height></Resolution>
                  <Encoding>H264</Encoding>
                </VideoEncoderConfiguration>
              </Profiles>
              <Profiles token="sub">
                <Name>Sub</Name>
                <VideoEncoderConfiguration>
                  <Resolution><Width>640</Width><Height>480</Height></Resolution>
                  <Encoding>H265</Encoding>
                </VideoEncoderConfiguration>
              </Profiles>
            </GetProfilesResponse>
            """)

        let profiles = try client.parseProfiles(Data(xml.utf8))

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].token, "main")
        XCTAssertEqual(profiles[1].token, "sub")
        XCTAssertEqual(profiles[1].width, 640)
        XCTAssertEqual(profiles[1].codec, "H265")
    }

    func testParseProfilesUsesTokenAsNameWhenMissing() throws {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <GetProfilesResponse>
              <Profiles token="tok_1">
                <VideoEncoderConfiguration>
                  <Resolution><Width>1280</Width><Height>720</Height></Resolution>
                  <Encoding>H264</Encoding>
                </VideoEncoderConfiguration>
              </Profiles>
            </GetProfilesResponse>
            """)

        let profiles = try client.parseProfiles(Data(xml.utf8))

        XCTAssertEqual(profiles[0].name, "tok_1")
    }

    func testParseProfilesThrowsOnEmpty() {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: "<GetProfilesResponse/>")

        XCTAssertThrowsError(try client.parseProfiles(Data(xml.utf8))) { error in
            XCTAssertTrue(error is ONVIFError)
        }
    }

    // MARK: - parseStreamURI

    func testParseStreamURI() throws {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <GetStreamUriResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
              <MediaUri>
                <Uri>rtsp://192.168.1.50:554/stream1</Uri>
              </MediaUri>
            </GetStreamUriResponse>
            """)

        let uri = try client.parseStreamURI(Data(xml.utf8))
        XCTAssertEqual(uri, "rtsp://192.168.1.50:554/stream1")
    }

    func testParseStreamURIThrowsWhenMissing() {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <GetStreamUriResponse>
              <MediaUri/>
            </GetStreamUriResponse>
            """)

        XCTAssertThrowsError(try client.parseStreamURI(Data(xml.utf8)))
    }

    // MARK: - parseDeviceInformation

    func testParseDeviceInformation() throws {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <GetDeviceInformationResponse xmlns="http://www.onvif.org/ver10/device/wsdl">
              <Manufacturer>Acme Corp</Manufacturer>
              <Model>X200</Model>
              <FirmwareVersion>2.4.1</FirmwareVersion>
              <SerialNumber>SN123456</SerialNumber>
              <HardwareId>HW-001</HardwareId>
            </GetDeviceInformationResponse>
            """)

        let info = try client.parseDeviceInformation(Data(xml.utf8))

        XCTAssertEqual(info.manufacturer, "Acme Corp")
        XCTAssertEqual(info.model, "X200")
        XCTAssertEqual(info.firmwareVersion, "2.4.1")
        XCTAssertEqual(info.serialNumber, "SN123456")
        XCTAssertEqual(info.hardwareId, "HW-001")
    }

    func testParseDeviceInformationWithMissingFields() throws {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <GetDeviceInformationResponse>
              <Manufacturer>TestCo</Manufacturer>
            </GetDeviceInformationResponse>
            """)

        let info = try client.parseDeviceInformation(Data(xml.utf8))

        XCTAssertEqual(info.manufacturer, "TestCo")
        XCTAssertNil(info.model)
        XCTAssertNil(info.firmwareVersion)
        XCTAssertNil(info.serialNumber)
        XCTAssertNil(info.hardwareId)
    }

    func testParseDeviceInformationReturnsDefaultsWhenNoResponse() throws {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: "<SomethingElse/>")

        let info = try client.parseDeviceInformation(Data(xml.utf8))

        XCTAssertNil(info.manufacturer)
        XCTAssertNil(info.model)
    }

    // MARK: - extractSOAPFault

    func testExtractSOAPFault() {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: """
            <s:Fault>
              <s:Code><s:Value>s:Sender</s:Value></s:Code>
              <s:Reason>
                <s:Text xml:lang="en">Authentication failed</s:Text>
              </s:Reason>
            </s:Fault>
            """)

        let fault = client.extractSOAPFault(from: Data(xml.utf8))
        XCTAssertEqual(fault, "Authentication failed")
    }

    func testExtractSOAPFaultReturnsNilWhenNoFault() {
        guard let client else { XCTFail("client not initialized"); return }
        let xml = soapEnvelope(body: "<GetProfilesResponse/>")

        let fault = client.extractSOAPFault(from: Data(xml.utf8))
        XCTAssertNil(fault)
    }

    func testExtractSOAPFaultReturnsNilForInvalidXML() {
        guard let client else { XCTFail("client not initialized"); return }
        let fault = client.extractSOAPFault(from: Data("garbage".utf8))
        XCTAssertNil(fault)
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
