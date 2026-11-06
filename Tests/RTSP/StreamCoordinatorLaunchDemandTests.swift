import Foundation
@testable import LemurCam
import os
import XCTest

/// Locks demand at launch, when `start()` seeds it from probes instead of the
/// consumer notifications it missed. The microphone probe is the process's first
/// CoreAudio call and used to run on the main thread, which it can block for a long
/// time right after boot; it now runs on a background queue and its answer arrives
/// later as an ordinary demand change. Neither that answer nor the notifications
/// that follow a probe may reconnect the stream the launch brought up.
@MainActor
internal final class StreamCoordinatorLaunchDemandTests: XCTestCase {
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

    private func makeHarness(
        cameraInUse: Bool = false,
        microphone: @escaping @Sendable () -> Bool = { false }
    ) -> CoordinatorHarness {
        let harness = CoordinatorHarness(
            rtspSources: ["cam-a"], cameraConsumerProbe: { cameraInUse }, audioConsumerProbe: microphone
        )
        fixture = harness
        return harness
    }

    /// The camera probe finds an app already using the camera: the stream connects
    /// once. The extension's own notification for that consumer, and the microphone
    /// probe's later answer, are not demand edges and must not reconnect it.
    func testCameraInUseAtLaunchConnectsOnce() async {
        let harness = makeHarness(cameraInUse: true, microphone: { true })

        harness.coordinator.start()
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        let cancelsAfterLaunch = harness.pipeline.silentCancels
        harness.coordinator.simulateCameraConsumerChange(active: true)
        let micSeen = await waitUntil { harness.coordinator.hasAudioConsumers }

        XCTAssertTrue(micSeen)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"], "no reconnect after launch")
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsAfterLaunch)
    }

    func testMicrophoneInUseAtLaunchStartsTheStreamOnceTheProbeAnswers() async {
        let calledOnMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let harness = makeHarness {
            calledOnMain.withLock { $0.append(Thread.isMainThread) }
            return true
        }

        harness.coordinator.start()
        let connected = await waitUntil { harness.pipeline.connectedURLs == ["rtsp://cam-a"] }

        XCTAssertTrue(connected, "a microphone in use at launch must bring the stream up")
        XCTAssertEqual(calledOnMain.withLock { $0 }, [false], "the CoreAudio probe must not block the main thread")
    }

    /// A consumer notification that arrives while the probe still runs is newer than
    /// the probe's answer, so the answer is dropped.
    func testANotificationWhileTheProbeRunsWins() async throws {
        let release = DispatchSemaphore(value: 0)
        // Never leave the probe blocking the audio queue, even if an assertion fails.
        defer { release.signal() }
        let probeState = OSAllocatedUnfairLock(initialState: (started: false, finished: false))
        let harness = makeHarness {
            probeState.withLock { $0.started = true }
            release.wait()
            probeState.withLock { $0.finished = true }
            return false
        }
        harness.coordinator.start()
        let started = await waitUntil { probeState.withLock { $0.started } }
        XCTAssertTrue(started)

        harness.coordinator.simulateAudioConsumerChange(active: true)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        let cancelsAfterConnect = harness.pipeline.silentCancels
        release.signal()
        let finished = await waitUntil { probeState.withLock { $0.finished } }
        XCTAssertTrue(finished)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(harness.coordinator.hasAudioConsumers, "the stale probe must not clear the newer start")
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://cam-a"])
        XCTAssertEqual(harness.pipeline.silentCancels, cancelsAfterConnect, "nor pause the stream")
    }
}
