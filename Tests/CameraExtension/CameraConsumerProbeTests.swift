import CoreMediaIO
@testable import LemurCam
import XCTest

/// Pins how camera demand is seeded at launch (`StreamCoordinator.start()`) and
/// after CMIO discovery (`LemurCamModel`). It used to come from an app-group flag
/// the extension wrote, but the extension runs as `_cmiodalassistants`, so the
/// flag never reached the app. It now comes from the device's
/// `kCMIODevicePropertyDeviceIsRunningSomewhere`, and every failure reads as
/// "no consumer" (the old effective behavior).
internal final class CameraConsumerProbeTests: XCTestCase {

    private let deviceID: CMIODeviceID = 42

    func testRunningDeviceHasAnExternalConsumer() {
        XCTAssertTrue(CameraConsumerProbe.hasExternalConsumer(deviceID: deviceID) { _ in 1 })
        // Any non-zero value counts as running.
        XCTAssertTrue(CameraConsumerProbe.hasExternalConsumer(deviceID: deviceID) { _ in 2 })
    }

    func testIdleDeviceHasNoConsumer() {
        XCTAssertFalse(CameraConsumerProbe.hasExternalConsumer(deviceID: deviceID) { _ in 0 })
    }

    func testUnreadablePropertyMeansNoConsumer() {
        XCTAssertFalse(CameraConsumerProbe.hasExternalConsumer(deviceID: deviceID) { _ in nil })
    }

    func testMissingDeviceMeansNoConsumerWithoutReading() {
        var reads = 0
        let result = CameraConsumerProbe.hasExternalConsumer(deviceID: nil) { _ in
            reads += 1
            return 1
        }
        XCTAssertFalse(result)
        XCTAssertEqual(reads, 0, "no device, nothing to read")
    }

    func testReadsTheGivenDevice() {
        var readDevice: CMIODeviceID?
        _ = CameraConsumerProbe.hasExternalConsumer(deviceID: deviceID) { id in
            readDevice = id
            return 0
        }
        XCTAssertEqual(readDevice, deviceID)
    }
}
