import CoreMedia
import CoreMediaIO
@testable import LemurCam
import XCTest

/// Pins how `LemurCamStreamState` invalidates its cached CMIO device/sink-stream
/// IDs. They used to be cached forever: once discovery succeeded, `prepareRetry`
/// returned `.idle`, so `onCameraReady` could never rediscover, and after a
/// disable/re-enable, Repair, or an extension crash while streaming (no
/// `consumerStopped`, so `isStreaming` stuck at true and `beginStarting` refused)
/// video stayed dead until the app relaunched.
internal final class LemurCamStreamDiscoveryTests: XCTestCase {

    private let maxRetries = 3
    private let oldDevice: (deviceID: CMIODeviceID, streamID: CMIOStreamID) = (deviceID: 10, streamID: 11)
    private let newDevice: (deviceID: CMIODeviceID, streamID: CMIOStreamID) = (deviceID: 20, streamID: 21)

    // MARK: - Discovery gating

    func testNoDiscoveryUntilRequested() {
        let state = LemurCamStreamState()
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .idle)
        // Device-list changes don't start discovery before setup asked for it.
        XCTAssertEqual(state.deviceListChanged(.lemur(oldDevice.deviceID)), .unchanged)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .idle)
    }

    func testRequestedDiscoveryRetriesUntilTheBudgetRunsOut() {
        let state = LemurCamStreamState()
        state.requestDiscovery()

        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1))
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .idle, "a pass is already in flight")
        XCTAssertEqual(state.applyDiscoveryResult(nil), .retry)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 2))
        XCTAssertEqual(state.applyDiscoveryResult(nil), .retry)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 3))
        XCTAssertEqual(state.applyDiscoveryResult(nil), .retry)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .failed)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .idle, "failure is reported once")
    }

    func testOnlyOneRetryTimerIsArmedAtATime() {
        let state = LemurCamStreamState()
        XCTAssertTrue(state.claimRetrySchedule())
        XCTAssertFalse(state.claimRetrySchedule())
        _ = state.prepareRetry(maxRetries: maxRetries)
        XCTAssertTrue(state.claimRetrySchedule(), "firing the timer frees the slot")
    }

    func testFirstDiscoveryCachesTheDevice() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        XCTAssertTrue(state.isReady)

        let snapshot = try XCTUnwrap(state.beginStarting())
        XCTAssertEqual(snapshot.deviceID, oldDevice.deviceID)
        XCTAssertEqual(snapshot.streamID, oldDevice.streamID)
        XCTAssertFalse(snapshot.hasConnectedOnce)
    }

    // MARK: - Re-running discovery (onCameraReady)

    func testOnCameraReadyRediscoversEvenWhenReady() {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))

        state.requestDiscovery()
        XCTAssertEqual(
            state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1),
            "discovery must re-run on every onCameraReady, not stay idle once ready"
        )
    }

    func testRediscoveringTheSameDeviceKeepsTheLiveStream() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        try connect(state)

        discover(oldDevice, in: state, expecting: .alreadyReady)
        XCTAssertTrue(state.isStreaming)
        XCTAssertTrue(state.hasStreamResources)
        XCTAssertNil(state.beginStarting(), "still streaming on the same device")
    }

    func testRediscoveringANewDeviceDropsTheOldStream() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        try connect(state)

        discover(newDevice, in: state, expecting: .ready(deviceID: newDevice.deviceID))
        XCTAssertFalse(state.isStreaming)
        XCTAssertFalse(state.hasStreamResources)

        let snapshot = try XCTUnwrap(state.beginStarting(), "a new device must be startable")
        XCTAssertEqual(snapshot.deviceID, newDevice.deviceID)
        XCTAssertEqual(snapshot.streamID, newDevice.streamID)
        XCTAssertFalse(snapshot.hasConnectedOnce, "a new device needs a fresh buffer queue, not a resume")
    }

    func testMissedRediscoveryKeepsTheCachedDevice() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        try connect(state)

        state.requestDiscovery()
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1))
        XCTAssertEqual(state.applyDiscoveryResult(nil), .alreadyReady)
        XCTAssertTrue(state.isStreaming)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .idle, "no retry loop while a device is cached")
    }

    // MARK: - Device-list changes

    func testUnrelatedDeviceListChangeKeepsEverything() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        try connect(state)

        XCTAssertEqual(state.deviceListChanged(.lemur(oldDevice.deviceID)), .unchanged)
        XCTAssertTrue(state.isReady)
        XCTAssertTrue(state.isStreaming)
        XCTAssertTrue(state.hasStreamResources)
    }

    func testLostDeviceDropsAStreamStuckAfterAnExtensionCrash() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        try connect(state)
        // The extension died while streaming: no consumerStopped arrives, so the
        // stream stays "streaming" and a new start is refused.
        XCTAssertNil(state.beginStarting())

        XCTAssertEqual(state.deviceListChanged(.empty), .deviceLost)
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.isStreaming)
        XCTAssertFalse(state.hasStreamResources)
        XCTAssertNil(state.beginStarting(), "no device to start on")
        XCTAssertNil(state.stopStreaming(), "nothing left to stop")
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .idle, "wait for the device to come back")
    }

    func testReturningDeviceIsRediscoveredAndStartsFresh() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        try connect(state)
        XCTAssertEqual(state.deviceListChanged(.empty), .deviceLost)

        XCTAssertEqual(state.deviceListChanged(.lemur(newDevice.deviceID)), .rediscover)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1))
        XCTAssertEqual(state.applyDiscoveryResult(newDevice), .ready(deviceID: newDevice.deviceID))

        let snapshot = try XCTUnwrap(state.beginStarting())
        XCTAssertEqual(snapshot.deviceID, newDevice.deviceID)
        XCTAssertFalse(snapshot.hasConnectedOnce)
    }

    func testReplacedDeviceInOneChangeDropsAndRediscovers() throws {
        let state = LemurCamStreamState()
        discover(oldDevice, in: state, expecting: .ready(deviceID: oldDevice.deviceID))
        try connect(state)

        XCTAssertEqual(state.deviceListChanged(.lemur(newDevice.deviceID)), .deviceReplaced)
        XCTAssertFalse(state.isReady)
        XCTAssertFalse(state.isStreaming)
        XCTAssertFalse(state.hasStreamResources)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1))
    }

    func testDeviceAppearingAfterSetupRequestStartsDiscovery() {
        let state = LemurCamStreamState()
        state.requestDiscovery()
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1))
        XCTAssertEqual(state.applyDiscoveryResult(nil), .retry)
        // Retries ran out before the device showed up.
        for attempt in 2...maxRetries {
            XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: attempt))
            XCTAssertEqual(state.applyDiscoveryResult(nil), .retry)
        }
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .failed)

        XCTAssertEqual(state.deviceListChanged(.lemur(newDevice.deviceID)), .rediscover)
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1), "fresh retry budget")
    }

    func testDeviceListChangeDuringAPassLeavesItToThatPass() {
        let state = LemurCamStreamState()
        state.requestDiscovery()
        XCTAssertEqual(state.prepareRetry(maxRetries: maxRetries), .discover(attempt: 1))

        XCTAssertEqual(state.deviceListChanged(.lemur(newDevice.deviceID)), .unchanged)
        XCTAssertEqual(state.applyDiscoveryResult(newDevice), .ready(deviceID: newDevice.deviceID))
    }

    // MARK: - Helpers

    private func discover(
        _ device: (deviceID: CMIODeviceID, streamID: CMIOStreamID),
        in state: LemurCamStreamState,
        expecting expected: LemurCamStreamState.DiscoveryResultAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        state.requestDiscovery()
        guard case .discover = state.prepareRetry(maxRetries: maxRetries) else {
            XCTFail("discovery did not start", file: file, line: line)
            return
        }
        XCTAssertEqual(state.applyDiscoveryResult(device), expected, file: file, line: line)
    }

    private func connect(_ state: LemurCamStreamState) throws {
        _ = try XCTUnwrap(state.beginStarting())
        var queue: CMSimpleQueue?
        XCTAssertEqual(CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: 1, queueOut: &queue), noErr)
        state.markStreamConnected(
            resources: CMIOStreamQueueResources(
                queue: SendableSimpleQueue(try XCTUnwrap(queue)),
                queueAlteredRegistration: CMIOStreamQueueAlteredRegistration()
            )
        )
        XCTAssertTrue(state.isStreaming)
    }
}
