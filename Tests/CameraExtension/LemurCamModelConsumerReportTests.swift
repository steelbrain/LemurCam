import CoreMediaIO
@testable import LemurCam
import os
import XCTest

/// Locks what `LemurCamModel` tells `StreamCoordinator` about camera consumers.
/// The extension posts no `consumerStopped` when it crashes or its device is
/// disabled, replaced or repaired, and the model's discovery probe alone decided
/// whether the sink stream started. The coordinator heard neither, so its camera
/// demand could outlive the consumer (the RTSP stream kept running and quitting
/// asked about a camera in use) or disagree with the sink (a sink fed no frames).
@MainActor
internal final class LemurCamModelConsumerReportTests: XCTestCase {
    private let device: (deviceID: CMIODeviceID, streamID: CMIOStreamID) = (deviceID: 10, streamID: 11)

    /// A model whose probe sees no consumer (so it never starts a sink stream on a
    /// real CMIO device), recording the devices it probed and what it reported.
    private struct Fixture {
        let model: LemurCamModel
        let probedDevices = OSAllocatedUnfairLock<[CMIODeviceID]>(initialState: [])
        let reportedConsumers = OSAllocatedUnfairLock<[Bool]>(initialState: [])

        var probed: [CMIODeviceID] { probedDevices.withLock { $0 } }
        var reports: [Bool] { reportedConsumers.withLock { $0 } }

        init() {
            let probes = probedDevices
            model = LemurCamModel { deviceID in
                probes.withLock { $0.append(deviceID) }
                return false
            }
            let recorded = reportedConsumers
            model.onExternalConsumerChange = { hasConsumer in
                recorded.withLock { $0.append(hasConsumer) }
            }
        }
    }

    func testDiscoveryOfANewDeviceReportsTheProbesAnswer() {
        let fixture = Fixture()

        fixture.model.applyDiscoveryResult(device)

        XCTAssertEqual(fixture.probed, [device.deviceID])
        XCTAssertEqual(fixture.reports, [false])
    }

    /// Finding the cached device again must not probe: the app's own sink stream
    /// may run on it, and "running somewhere" counts that too.
    func testRediscoveringTheCachedDeviceReportsNothing() {
        let fixture = Fixture()
        fixture.model.applyDiscoveryResult(device)

        fixture.model.applyDiscoveryResult(device)
        fixture.model.applyDiscoveryResult(nil)

        XCTAssertEqual(fixture.probed, [device.deviceID])
        XCTAssertEqual(fixture.reports, [false])
    }

    func testLosingTheDeviceReportsNoConsumer() {
        let fixture = Fixture()
        fixture.model.applyDiscoveryResult(device)

        fixture.model.applyDeviceListChange(.lemur(device.deviceID))
        XCTAssertEqual(fixture.reports, [false], "an unrelated device-list change reports nothing")

        fixture.model.applyDeviceListChange(.empty)
        XCTAssertEqual(fixture.reports, [false, false], "a lost device takes its consumers with it")
    }

    func testDeviceListChangesWithoutACachedDeviceReportNothing() {
        let fixture = Fixture()

        fixture.model.applyDeviceListChange(.empty)

        XCTAssertEqual(fixture.reports, [])
    }
}
