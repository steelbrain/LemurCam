@testable import LemurCam
import XCTest
import XMLKit

/// WS-Security `Created` used to come straight from the Mac's clock, so a camera
/// whose clock had drifted rejected every signed request. The client now reads the
/// device's time with the unauthenticated GetSystemDateAndTime once and signs on the
/// device's clock. Canned responses only; no network.
internal final class ONVIFClockTests: XCTestCase {
    private func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
                    xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
                    xmlns:tt="http://www.onvif.org/ver10/schema">
          <s:Body>\(body)</s:Body>
        </s:Envelope>
        """
    }

    private func dateAndTimeResponse(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return envelope("""
            <tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime>
              <tt:DateTimeType>Manual</tt:DateTimeType>
              <tt:UTCDateTime>
                <tt:Time><tt:Hour>\(parts.hour ?? 0)</tt:Hour><tt:Minute>\(parts.minute ?? 0)</tt:Minute>
                  <tt:Second>\(parts.second ?? 0)</tt:Second></tt:Time>
                <tt:Date><tt:Year>\(parts.year ?? 0)</tt:Year><tt:Month>\(parts.month ?? 0)</tt:Month>
                  <tt:Day>\(parts.day ?? 0)</tt:Day></tt:Date>
              </tt:UTCDateTime>
            </tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>
            """)
    }

    private let profilesResponse = """
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>
        <GetProfilesResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
        <Profiles token="main"><Name>Main</Name></Profiles></GetProfilesResponse>
        </s:Body></s:Envelope>
        """

    // MARK: - Parsing

    func testParsesUTCDateTime() throws {
        let data = Data(dateAndTimeResponse(Date(timeIntervalSince1970: 1_767_323_045)).utf8)
        let parsed = try XCTUnwrap(ONVIFClient.parseSystemDateAndTime(data))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_767_323_045, accuracy: 0.5)
    }

    func testIgnoresResponseWithOnlyLocalTime() {
        let xml = envelope("""
            <tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:LocalDateTime>
              <tt:Time><tt:Hour>1</tt:Hour><tt:Minute>2</tt:Minute><tt:Second>3</tt:Second></tt:Time>
              <tt:Date><tt:Year>2026</tt:Year><tt:Month>1</tt:Month><tt:Day>2</tt:Day></tt:Date>
            </tt:LocalDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>
            """)
        XCTAssertNil(ONVIFClient.parseSystemDateAndTime(Data(xml.utf8)))
    }

    func testRejectsImpossibleDate() {
        let xml = envelope("""
            <tt:UTCDateTime>
              <tt:Time><tt:Hour>25</tt:Hour><tt:Minute>0</tt:Minute><tt:Second>0</tt:Second></tt:Time>
              <tt:Date><tt:Year>2026</tt:Year><tt:Month>2</tt:Month><tt:Day>30</tt:Day></tt:Date>
            </tt:UTCDateTime>
            """)
        XCTAssertNil(ONVIFClient.parseSystemDateAndTime(Data(xml.utf8)))
    }

    func testOffsetUsesRoundTripMidpoint() {
        let sent = Date(timeIntervalSince1970: 1000)
        let received = Date(timeIntervalSince1970: 1002)
        let device = Date(timeIntervalSince1970: 4601)
        XCTAssertEqual(
            ONVIFClient.clockOffset(deviceTime: device, requestSent: sent, responseReceived: received), 3600
        )
    }

    // MARK: - Signing on the device clock

    private struct Exchange {
        let operation: String
        let created: Date?
    }

    /// Runs `getProfiles` against a stub camera whose GetSystemDateAndTime reply comes
    /// from `clockReply`, and returns what each request carried.
    private func runGetProfiles(
        username: String?, clockReply: @escaping @Sendable () -> ONVIFStubURLProtocol.Reply
    ) async throws -> [Exchange] {
        let host = "onvif-clock-\(UUID().uuidString).invalid"
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let captured = CapturedBodies()
        let profiles = Data(profilesResponse.utf8)
        ONVIFStubURLProtocol.register(host: host) { _, body in
            captured.append(body)
            if String(bytes: body, encoding: .utf8)?.contains("GetSystemDateAndTime") == true {
                return clockReply()
            }
            return ONVIFStubURLProtocol.Reply(body: profiles)
        }
        let client = ONVIFClient(
            host: host, port: 80, username: username, password: username.map { _ in "secret" },
            configuration: ONVIFStubURLProtocol.configuration()
        )
        _ = try await client.getProfiles()
        _ = try await client.getProfiles()
        return try captured.all.map(Self.exchange)
    }

    private static func exchange(_ body: Data) throws -> Exchange {
        let root = try ONVIFXML.parse(body)
        let operation = try XCTUnwrap(root["Body"]?.elementChildren.first?.name)
        var created: Date?
        root.findElements(named: "Created") { element in
            created = element.getText().flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        return Exchange(operation: operation, created: created)
    }

    func testSignsOnDeviceClockAndMeasuresOnce() async throws {
        let skewed = Date().addingTimeInterval(3600)
        let reply = dateAndTimeResponse(skewed)
        let exchanges = try await runGetProfiles(username: "viewer") {
            ONVIFStubURLProtocol.Reply(body: Data(reply.utf8))
        }

        XCTAssertEqual(exchanges.map(\.operation), ["GetSystemDateAndTime", "GetProfiles", "GetProfiles"])
        XCTAssertNil(exchanges[0].created, "GetSystemDateAndTime must be sent unsigned")
        for exchange in exchanges.dropFirst() {
            let created = try XCTUnwrap(exchange.created)
            XCTAssertEqual(created.timeIntervalSince(skewed), 0, accuracy: 5)
        }
    }

    func testFallsBackToLocalClockWhenDeviceCannotReportTime() async throws {
        let exchanges = try await runGetProfiles(username: "viewer") {
            ONVIFStubURLProtocol.Reply(status: 500)
        }

        XCTAssertEqual(exchanges.map(\.operation), ["GetSystemDateAndTime", "GetProfiles", "GetProfiles"])
        let created = try XCTUnwrap(exchanges.last?.created)
        XCTAssertEqual(created.timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testUnsignedClientSkipsClockRequest() async throws {
        let exchanges = try await runGetProfiles(username: nil) {
            XCTFail("an unsigned client should not ask for the time")
            return ONVIFStubURLProtocol.Reply(status: 500)
        }
        XCTAssertEqual(exchanges.map(\.operation), ["GetProfiles", "GetProfiles"])
    }
}
