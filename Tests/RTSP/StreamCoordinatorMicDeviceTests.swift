@testable import LemurCam
import os
import XCTest

/// Locks microphone demand when the virtual microphone's driver goes away while an
/// app records. The helper moves the driver out and restarts coreaudiod: StopIO
/// never runs and the removed driver never runs Initialize, so no
/// `consumerStopped` arrives, and demand used to stay on for good, keeping the
/// camera stream up for no one. The coordinator now reads the device again after
/// every HAL device-list change. A camera consumer's video must ride through it.
@MainActor
internal final class StreamCoordinatorMicDeviceTests: XCTestCase {
    private var fixture: CoordinatorHarness?
    /// What the microphone probe reports; the driver's removal turns it off.
    private let micRunning = OSAllocatedUnfairLock(initialState: true)

    override func setUp() async throws {
        try await super.setUp()
        micRunning.withLock { $0 = true }
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// Launch while an app records from the virtual microphone, with the HAL
    /// device-list listener installed.
    private func launchWithMicrophoneInUse(cameraInUse: Bool) async -> CoordinatorHarness {
        let probeState = micRunning
        let harness = CoordinatorHarness(
            rtspSources: ["cam-a"], cameraConsumerProbe: { cameraInUse },
            audioConsumerProbe: { probeState.withLock { $0 } }
        )
        fixture = harness
        harness.coordinator.start()
        let ready = await waitUntil {
            harness.coordinator.hasAudioConsumers && harness.isObservingAudioDevices
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        return harness
    }

    func testRemovingTheMicrophoneDriverClearsMicrophoneDemand() async throws {
        let harness = await launchWithMicrophoneInUse(cameraInUse: false)
        let camera = try XCTUnwrap(harness.manager.sources.first?.id)
        let cancelsBefore = harness.pipeline.silentCancels

        micRunning.withLock { $0 = false }
        harness.simulateAudioDeviceListChange()
        let cleared = await waitUntil { !harness.coordinator.hasAudioConsumers }

        XCTAssertTrue(cleared, "a removed microphone has no consumer")
        XCTAssertFalse(harness.coordinator.hasDemand)
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore + 1, "nothing needs the stream any more")
        XCTAssertEqual(harness.status(camera), .disconnected)
    }

    func testRemovingTheMicrophoneDriverDoesNotReconnectVideoForACameraConsumer() async {
        let harness = await launchWithMicrophoneInUse(cameraInUse: true)
        let cancelsBefore = harness.pipeline.silentCancels

        micRunning.withLock { $0 = false }
        harness.simulateAudioDeviceListChange()
        let cleared = await waitUntil { !harness.coordinator.hasAudioConsumers }

        XCTAssertTrue(cleared)
        XCTAssertTrue(harness.coordinator.hasDemand, "the camera consumer still needs the stream")
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"], "video must not reconnect")
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore)
    }

    /// Other devices come and go (headsets, AirPods): with the microphone still in
    /// use, a device-list change keeps its demand and the stream.
    func testAnUnrelatedDeviceChangeKeepsMicrophoneDemand() async throws {
        let harness = await launchWithMicrophoneInUse(cameraInUse: false)
        let cancelsBefore = harness.pipeline.silentCancels

        harness.simulateAudioDeviceListChange()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(harness.coordinator.hasAudioConsumers)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsBefore)
    }
}
