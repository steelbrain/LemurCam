@testable import LemurCam
import XCTest

/// Pins that the Video Buffer setting reaches the jitter buffer through the
/// coordinator: the one it starts with, and a change made in Settings on the
/// running stream, without a reconnect.
@MainActor
internal final class StreamCoordinatorVideoBufferTests: XCTestCase {
    private var fixture: CoordinatorHarness?

    override func setUp() async throws {
        try await super.setUp()
        fixture = nil
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// The default: the tuned buffer, which holds frames before it sends any on.
    func testTheDefaultBuffersAsBefore() async throws {
        let harness = CoordinatorHarness()
        fixture = harness
        XCTAssertEqual(harness.coordinator.videoBuffer, .defaultValue)

        try await connectCamera(in: harness)
        try harness.deliverDecodedFrames(Tuning.jitterBufferPrimingThreshold - 1)
        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames)
        try harness.deliverDecodedFrames(1)
        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames)
    }

    /// Started with Off, the first decoded frame goes on at once.
    func testTheSettingAppliesFromTheStart() async throws {
        let harness = CoordinatorHarness(videoBuffer: .off)
        fixture = harness
        XCTAssertEqual(harness.coordinator.videoBuffer, .off)

        try await connectCamera(in: harness)
        try harness.deliverDecodedFrames(1)
        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames)
    }

    /// A change in Settings reaches the stream that is running, which keeps its
    /// connection.
    func testAChangeAppliesToTheRunningStream() async throws {
        let harness = CoordinatorHarness()
        fixture = harness
        try await connectCamera(in: harness)
        try harness.deliverDecodedFrames(1)
        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames)
        let connections = harness.pipeline.connectedURLs.count
        let cancels = harness.pipeline.silentCancels

        harness.coordinator.videoBuffer = .off
        XCTAssertEqual(harness.coordinator.videoBuffer, .off)
        try harness.deliverDecodedFrames(1)

        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames)
        XCTAssertEqual(harness.pipeline.connectedURLs.count, connections, "the stream was not reconnected")
        XCTAssertEqual(harness.pipeline.silentCancels, cancels)
    }

    /// The setting outlives a switch to another camera.
    func testTheSettingCarriesOverToTheNextCamera() async throws {
        let harness = CoordinatorHarness(videoBuffer: .off)
        fixture = harness
        try await connectCamera(in: harness)
        let back = try XCTUnwrap(harness.addRTSP("back"))

        harness.manager.setActiveSource(id: back)
        XCTAssertFalse(harness.coordinator.isForwardingCameraFrames)
        try harness.deliverDecodedFrames(1)

        XCTAssertEqual(harness.coordinator.videoBuffer, .off)
        XCTAssertTrue(harness.coordinator.isForwardingCameraFrames)
    }

    /// Add a camera, make the preview want it, and report it streaming.
    private func connectCamera(in harness: CoordinatorHarness) async throws {
        let camera = try XCTUnwrap(harness.addRTSP("cam"))
        harness.coordinator.previewStore.isPreviewEnabled = true
        harness.pipeline.emit(.streaming)
        let connected = await waitUntil { harness.status(camera) == .connected }
        XCTAssertTrue(connected)
    }
}
