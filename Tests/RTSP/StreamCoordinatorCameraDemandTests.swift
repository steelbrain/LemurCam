import CoreMediaIO
@testable import LemurCam
import XCTest

/// Locks how `StreamCoordinator`'s camera demand follows what `LemurCamModel`
/// learns from CMIO. Demand used to come only from the extension's consumer
/// notifications and the launch probe. An extension that crashed or was disabled,
/// replaced or repaired while an app used it never posted `consumerStopped`, so the
/// RTSP stream ran on with no consumer and quitting asked about a camera in use.
/// And when the model's discovery probe saw a consumer the launch probe had not,
/// the sink stream started but the pipeline stayed down: a frozen picture.
@MainActor
internal final class StreamCoordinatorCameraDemandTests: XCTestCase {
    private var fixture: CoordinatorHarness?
    private let device: (deviceID: CMIODeviceID, streamID: CMIOStreamID) = (deviceID: 10, streamID: 11)

    override func setUp() async throws {
        try await super.setUp()
        fixture = CoordinatorHarness()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testLosingTheCameraDeviceClearsCameraDemand() throws {
        let harness = try XCTUnwrap(fixture)
        _ = harness.addRTSP("cam-a")
        let model = harness.coordinator.model
        model.applyDiscoveryResult(device)
        harness.coordinator.simulateCameraConsumerChange(active: true)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        let cancelsBefore = harness.pipeline.silentCancels

        model.applyDeviceListChange(.empty)

        XCTAssertFalse(harness.coordinator.hasExternalConsumers, "quitting must not ask about a camera in use")
        XCTAssertFalse(harness.coordinator.hasDemand)
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore + 1, "the stream must pause")
    }

    /// The model's discovery probe saw a consumer and started the sink stream, so
    /// the pipeline must run to feed it.
    func testAConsumerSeenAtDiscoveryRaisesCameraDemand() throws {
        let harness = try XCTUnwrap(fixture)
        _ = harness.addRTSP("cam-a")
        XCTAssertTrue(harness.pipeline.connectedURLs.isEmpty)
        let report = try XCTUnwrap(harness.coordinator.model.onExternalConsumerChange)

        report(true)

        XCTAssertTrue(harness.coordinator.hasExternalConsumers)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
    }

    /// The discovery probe is the later, device-specific answer: when it finds no
    /// consumer, demand an earlier signal raised goes away with it.
    func testDiscoveryFindingNoConsumerClearsEarlierCameraDemand() throws {
        let harness = try XCTUnwrap(fixture)
        _ = harness.addRTSP("cam-a")
        harness.coordinator.simulateCameraConsumerChange(active: true)
        let cancelsBefore = harness.pipeline.silentCancels

        harness.coordinator.model.applyDiscoveryResult(device)

        XCTAssertFalse(harness.coordinator.hasExternalConsumers)
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore + 1)
    }

    /// Losing the camera device while the microphone still needs the stream must
    /// not reconnect it.
    func testLosingTheCameraDeviceKeepsAStreamTheMicrophoneUses() throws {
        let harness = try XCTUnwrap(fixture)
        _ = harness.addRTSP("cam-a")
        harness.coordinator.model.applyDiscoveryResult(device)
        harness.coordinator.simulateCameraConsumerChange(active: true)
        harness.coordinator.simulateAudioConsumerChange(active: true)
        let cancelsBefore = harness.pipeline.silentCancels

        harness.coordinator.model.applyDeviceListChange(.empty)

        XCTAssertTrue(harness.coordinator.hasDemand)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore)
    }
}
