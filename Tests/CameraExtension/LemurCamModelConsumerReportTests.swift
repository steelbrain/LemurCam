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

    /// A model whose probe sees no consumer and which never hears the extension's
    /// system-wide consumer notifications (so it never starts a sink stream on
    /// whatever real CMIO objects have the fake IDs), and whose device-list reads
    /// return `deviceList`, recording the devices it probed, how often it read the
    /// list, and what it reported.
    private struct Fixture {
        let model: LemurCamModel
        let probedDevices = OSAllocatedUnfairLock<[CMIODeviceID]>(initialState: [])
        let deviceListReads = OSAllocatedUnfairLock(initialState: 0)
        let reportedConsumers = OSAllocatedUnfairLock<[Bool]>(initialState: [])

        var probed: [CMIODeviceID] { probedDevices.withLock { $0 } }
        var listReads: Int { deviceListReads.withLock { $0 } }
        var reports: [Bool] { reportedConsumers.withLock { $0 } }

        init(deviceList: CMIODeviceList = .empty) {
            let probes = probedDevices
            let reads = deviceListReads
            model = LemurCamModel(
                consumerProbe: { deviceID in
                    probes.withLock { $0.append(deviceID) }
                    return false
                },
                deviceListReader: {
                    reads.withLock { $0 += 1 }
                    return deviceList
                },
                consumerObserver: { _ in nil },
                formatWriter: { _, _ in }
            )
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

    /// A device-list change that couldn't be read, or that didn't identify the
    /// device, used to report no consumer: the camera stream paused under an app
    /// still showing it. It reports nothing, and the list is read again.
    func testAnUnidentifiedDeviceListReportsNothingAndIsReadAgain() async {
        let fixture = Fixture(deviceList: .lemur(device.deviceID))
        fixture.model.applyDiscoveryResult(device)

        fixture.model.applyDeviceListChange(.unreadable)
        XCTAssertEqual(fixture.reports, [false], "only discovery's report")

        let readAgain = await waitUntil(timeout: 5) { fixture.listReads == 1 }
        XCTAssertTrue(readAgain, "the list must be read again")
        XCTAssertEqual(fixture.reports, [false])
    }

    /// The device did go away during the unidentified change: the second read
    /// finds it gone and reports that its consumers went with it.
    func testARecheckThatFindsTheDeviceGoneReportsNoConsumer() async {
        let fixture = Fixture(deviceList: .empty)
        fixture.model.applyDiscoveryResult(device)

        fixture.model.applyDeviceListChange(.read(deviceIDs: [device.deviceID], lemurDeviceID: nil))
        XCTAssertEqual(fixture.reports, [false], "only discovery's report")

        let reported = await waitUntil(timeout: 5) { fixture.reports.count == 2 }
        XCTAssertTrue(reported, "the recheck must report the lost device")
        XCTAssertEqual(fixture.reports, [false, false])
        XCTAssertEqual(fixture.listReads, 1)
    }
}
