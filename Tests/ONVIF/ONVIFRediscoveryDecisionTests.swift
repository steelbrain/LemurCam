@testable import LemurCam
import XCTest

/// The pure half of ONVIF rediscovery: which failures justify a WS-Discovery scan,
/// and what a scan result means for the saved address. The resolve flow itself is
/// covered by ONVIFRediscoveryTests.
internal final class ONVIFRediscoveryDecisionTests: XCTestCase {
    private static let uuid = "2b9c0b1e-0000-4000-8000-00000000c0de"

    private func device(host: String, port: Int = 80, uuid: String = uuid) -> DiscoveredDevice {
        DiscoveredDevice(
            endpointUUID: uuid, endpointURL: "http://\(host):\(port)/onvif/device_service",
            name: nil, manufacturer: nil, model: nil, host: host, port: port
        )
    }

    /// No answer, or an answer that is not this camera's ONVIF service (another device
    /// now at the address), triggers a scan. The camera's own refusals do not.
    func testWhichFailuresTriggerRediscovery() {
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.networkError("refused")))
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.timedOut))
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.httpStatus(404)))
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.httpStatus(500)))
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.parseError))
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFXML.Rejection.malformed))
        XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFXML.Rejection.tooDeep))
        XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: ONVIFError.authenticationFailed))
        XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: ONVIFError.soapFault("Sender not authorized")))
        XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: ONVIFError.invalidURL))
        XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: CancellationError()))
    }

    func testOutcomeUnchangedWhenDeviceStillAtSavedAddress() {
        let info = ONVIFSourceInfo(deviceUUID: Self.uuid, host: "192.168.1.20", port: 80)
        let devices = [device(host: "192.168.1.20"), device(host: "192.168.1.20")]
        XCTAssertEqual(ONVIFRediscovery.outcome(for: info, among: devices), .unchanged)
    }

    func testOutcomeMovedCarriesNewAddressAndScheme() {
        let info = ONVIFSourceInfo(
            deviceUUID: Self.uuid, host: "192.168.1.20", port: 80, selectedProfileToken: "main"
        )
        let moved = DiscoveredDevice(
            endpointUUID: Self.uuid, endpointURL: "https://192.168.1.31:8443/onvif/device_service",
            name: nil, manufacturer: nil, model: nil, host: "192.168.1.31", port: 8443
        )
        var expected = info
        expected.host = "192.168.1.31"
        expected.port = 8443
        expected.useHTTPS = true
        XCTAssertEqual(ONVIFRediscovery.outcome(for: info, among: [device(host: "10.0.0.9", uuid: "other"), moved]),
                       .moved(expected))
    }

    func testOutcomeAmbiguousWhenTwoAddressesClaimTheDevice() {
        let info = ONVIFSourceInfo(deviceUUID: Self.uuid, host: "192.168.1.20", port: 80)
        let devices = [device(host: "192.168.1.31"), device(host: "192.168.1.66")]
        XCTAssertEqual(ONVIFRediscovery.outcome(for: info, among: devices), .ambiguous)
    }

    func testOutcomeNotFound() {
        let info = ONVIFSourceInfo(deviceUUID: Self.uuid, host: "192.168.1.20", port: 80)
        XCTAssertEqual(ONVIFRediscovery.outcome(for: info, among: [device(host: "1.2.3.4", uuid: "x")]), .notFound)
        let noUUID = ONVIFSourceInfo(host: "192.168.1.20", port: 80)
        XCTAssertEqual(ONVIFRediscovery.outcome(for: noUUID, among: [device(host: "192.168.1.31")]), .notFound)
    }
}
