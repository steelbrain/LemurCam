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
    /// now at the address), triggers a scan wherever the camera is saved.
    func testWhichFailuresTriggerRediscovery() {
        let named = ONVIFSourceInfo(deviceUUID: Self.uuid, host: "porch-cam.local", port: 80)
        for info in [named, ONVIFSourceInfo(deviceUUID: Self.uuid, host: "192.168.1.20", port: 80)] {
            XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.networkError("refused"), at: info))
            XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.timedOut, at: info))
            XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.httpStatus(404), at: info))
            XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.httpStatus(500), at: info))
            XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFError.parseError, at: info))
            XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFXML.Rejection.malformed, at: info))
            XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: ONVIFXML.Rejection.tooDeep, at: info))
            XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: ONVIFError.invalidURL, at: info))
            XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: CancellationError(), at: info))
        }
    }

    /// A rejected login or a SOAP fault may come from another camera that now has this
    /// camera's address (two cameras can swap addresses after a router reset). It
    /// leads to a scan only for a camera that a scan can find (it has a device UUID)
    /// and that is saved by its LAN IP address, which DHCP can hand to another device.
    func testRefusalsTriggerRediscoveryOnlyAtALANAddressWithADeviceUUID() {
        let refusals: [Error] = [ONVIFError.authenticationFailed, ONVIFError.soapFault("Sender not authorized")]
        let canMove = [
            ONVIFSourceInfo(deviceUUID: Self.uuid, host: "192.168.1.20", port: 80),
            ONVIFSourceInfo(deviceUUID: Self.uuid, host: "10.0.0.7", port: 8080, useHTTPS: true),
            ONVIFSourceInfo(deviceUUID: Self.uuid, host: "[fe80::1%en0]", port: 80)
        ]
        let stays = [
            ONVIFSourceInfo(deviceUUID: nil, host: "192.168.1.20", port: 80),
            ONVIFSourceInfo(deviceUUID: "", host: "192.168.1.20", port: 80),
            ONVIFSourceInfo(deviceUUID: Self.uuid, host: "porch-cam.local", port: 80),
            ONVIFSourceInfo(deviceUUID: Self.uuid, host: "203.0.113.5", port: 8080),
            ONVIFSourceInfo(deviceUUID: Self.uuid, host: "127.0.0.1", port: 8080)
        ]
        for error in refusals {
            for info in canMove {
                XCTAssertTrue(ONVIFRediscovery.shouldRediscover(after: error, at: info), "\(error) at \(info.host)")
            }
            for info in stays {
                XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: error, at: info), "\(error) at \(info.host)")
            }
        }
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
