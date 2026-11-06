import CoreMediaIO
import Foundation
import os

internal final class CMIOStreamQueueAlteredRegistration: Sendable {
    static let queueAlteredProc: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }

    private let refConAddress: UInt

    init() {
        let allocatedRefCon = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        self.refConAddress = UInt(bitPattern: allocatedRefCon)
    }

    deinit {
        refCon.deallocate()
    }

    var callback: CMIODeviceStreamQueueAlteredProc {
        Self.queueAlteredProc
    }

    var refCon: UnsafeMutableRawPointer {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: refConAddress) else {
            preconditionFailure("Invalid CMIO queue altered refCon pointer")
        }
        return pointer
    }
}

internal final class CMIOStreamQueueResources: Sendable {
    let queue: SendableSimpleQueue
    let queueAlteredRegistration: CMIOStreamQueueAlteredRegistration

    init(queue: SendableSimpleQueue, queueAlteredRegistration: CMIOStreamQueueAlteredRegistration) {
        self.queue = queue
        self.queueAlteredRegistration = queueAlteredRegistration
    }
}

/// Lock-protected discovery and sink-stream state for `LemurCamModel`. The cached
/// CMIO device/stream IDs are only valid for one registration of the LemurCam
/// device: when the extension is disabled, re-enabled, repaired, replaced or
/// crashes, the device goes away and comes back as a new CMIO object. So the
/// cache is dropped whenever the device list no longer shows the cached device
/// (`deviceListChanged`) and whenever a re-run discovery finds different IDs.
internal final class LemurCamStreamState: Sendable {
    internal struct StartSnapshot: Sendable {
        let deviceID: CMIODeviceID
        let streamID: CMIOStreamID
        let hasConnectedOnce: Bool
    }

    internal struct StopSnapshot: Sendable {
        let deviceID: CMIODeviceID
        let streamID: CMIOStreamID
    }

    internal enum RetryAction: Equatable {
        case idle
        case failed
        case discover(attempt: Int)
    }

    internal enum DiscoveryResultAction: Equatable {
        /// Discovery found the cached device again (same IDs), or failed while a
        /// device is still cached: keep the current sink stream as it is.
        case alreadyReady
        case retry
        /// A new or replaced device is cached; state tied to an older one is gone.
        case ready(deviceID: CMIODeviceID)
    }

    internal enum DeviceListChangeAction: Equatable {
        /// The cached device is still there, or discovery isn't wanted yet.
        case unchanged
        /// The cached device went away. Its IDs and sink stream are dropped; wait
        /// for the device to come back.
        case deviceLost
        /// Another device replaced the cached one. The old IDs and sink stream are
        /// dropped; run discovery for the new one.
        case deviceReplaced
        /// The device appeared while none was cached: run discovery.
        case rediscover
    }

    private struct State: Sendable {
        var streamResources: CMIOStreamQueueResources?
        var isStreaming = false
        var isStarting = false
        var deviceID: CMIODeviceID?
        var streamID: CMIOStreamID?
        var hasConnectedOnce = false
        var setupRetries = 0
        var isDiscovering = false
        /// A discovery pass is wanted and hasn't succeeded yet.
        var discoveryPending = false
        /// `requestDiscovery()` ran at least once (setup reported the camera ready),
        /// so device-list changes may start discovery on their own.
        var discoveryRequested = false
        /// A retry timer is armed; keeps duplicate timers from stacking up.
        var retryScheduled = false

        var isReady: Bool { deviceID != nil && streamID != nil }

        /// Forget the cached device and everything tied to it, including a sink
        /// stream that is stuck "streaming" because the extension died without
        /// posting `consumerStopped`. Returns the sink queue resources it dropped,
        /// whose queue may still hold retained buffers.
        @discardableResult
        mutating func dropDevice() -> CMIOStreamQueueResources? {
            let dropped = streamResources
            streamResources = nil
            isStreaming = false
            isStarting = false
            deviceID = nil
            streamID = nil
            hasConnectedOnce = false
            return dropped
        }

        mutating func armDiscovery() {
            discoveryPending = true
            setupRetries = 0
        }
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var isStreaming: Bool {
        state.withLock { $0.isStreaming }
    }

    var isReady: Bool {
        state.withLock { $0.isReady }
    }

    var hasStreamResources: Bool {
        state.withLock { $0.streamResources != nil }
    }

    func beginStarting() -> StartSnapshot? {
        state.withLock { state in
            guard !state.isStreaming,
                  !state.isStarting,
                  let deviceID = state.deviceID,
                  let streamID = state.streamID else {
                return nil
            }
            state.isStarting = true
            return StartSnapshot(
                deviceID: deviceID,
                streamID: streamID,
                hasConnectedOnce: state.hasConnectedOnce
            )
        }
    }

    func finishStartingWithoutStream() {
        state.withLock {
            $0.isStarting = false
        }
    }

    func markStreamResumed() {
        state.withLock {
            $0.isStreaming = true
            $0.isStarting = false
        }
    }

    func clearStreamResources() {
        state.withLock { state in
            state.streamResources = nil
        }
    }

    func markStreamConnected(resources: CMIOStreamQueueResources) {
        state.withLock {
            $0.streamResources = resources
            $0.hasConnectedOnce = true
            $0.isStreaming = true
            $0.isStarting = false
        }
    }

    func stopStreaming() -> StopSnapshot? {
        state.withLock { state in
            guard state.isStreaming,
                  let deviceID = state.deviceID,
                  let streamID = state.streamID else {
                return nil
            }
            state.isStreaming = false
            return StopSnapshot(deviceID: deviceID, streamID: streamID)
        }
    }

    func enqueue(_ buffer: CMSampleBuffer) -> Bool {
        let retainedBuffer = Unmanaged.passRetained(buffer)
        let bufferAddress = UInt(bitPattern: retainedBuffer.toOpaque())
        let wasEnqueued = state.withLock { state in
            guard state.isStreaming, let resources = state.streamResources else {
                return false
            }
            return resources.queue.enqueueRetainedElement(at: bufferAddress)
        }
        if !wasEnqueued {
            retainedBuffer.release()
        }
        return wasEnqueued
    }
}

// MARK: - Discovery

extension LemurCamStreamState {
    /// Ask for a discovery pass with a fresh retry budget. Called on every
    /// `onCameraReady`, including when a device is already cached: after the
    /// extension was disabled and re-enabled or repaired, the device may be a new
    /// CMIO object. A pass that finds the same IDs keeps the current sink stream.
    func requestDiscovery() {
        state.withLock {
            $0.discoveryRequested = true
            $0.armDiscovery()
        }
    }

    /// Claim the single retry timer. Returns false when one is already armed.
    func claimRetrySchedule() -> Bool {
        state.withLock { state in
            guard !state.retryScheduled else { return false }
            state.retryScheduled = true
            return true
        }
    }

    func prepareRetry(maxRetries: Int) -> RetryAction {
        state.withLock { state -> RetryAction in
            state.retryScheduled = false
            guard state.discoveryPending, !state.isDiscovering else {
                return .idle
            }
            guard state.setupRetries < maxRetries else {
                state.discoveryPending = false
                return .failed
            }
            state.setupRetries += 1
            state.isDiscovering = true
            return .discover(attempt: state.setupRetries)
        }
    }

    func applyDiscoveryResult(
        _ result: (deviceID: CMIODeviceID, streamID: CMIOStreamID)?
    ) -> DiscoveryResultAction {
        state.withLock { state in
            state.isDiscovering = false
            guard let result else {
                // A re-run that missed while a device is cached: had the device gone,
                // `deviceListChanged` would have dropped it, so keep it and stop.
                guard !state.isReady else {
                    state.discoveryPending = false
                    return .alreadyReady
                }
                return .retry
            }
            state.discoveryPending = false
            if state.deviceID == result.deviceID, state.streamID == result.streamID {
                return .alreadyReady
            }
            state.dropDevice()
            state.deviceID = result.deviceID
            state.streamID = result.streamID
            return .ready(deviceID: result.deviceID)
        }
    }

    /// The CMIO device list changed; `lemurDeviceID` is the LemurCam device's ID
    /// in the new list, or nil when it is absent. Drops the cache when the cached
    /// device is gone or was replaced, and arms discovery when a device is there
    /// to find. Device-list changes start discovery only after setup has asked for
    /// it once (`requestDiscovery`), and not while a pass is already in flight: that
    /// pass starts after this lookup (both run on the same serial queue), so its
    /// result is at least as fresh.
    func deviceListChanged(lemurDeviceID: CMIODeviceID?) -> DeviceListChangeAction {
        let (action, lostResources) = state.withLock { state -> (DeviceListChangeAction, CMIOStreamQueueResources?) in
            if let cachedDeviceID = state.deviceID {
                guard cachedDeviceID != lemurDeviceID else { return (.unchanged, nil) }
                let dropped = state.dropDevice()
                guard lemurDeviceID != nil else {
                    state.discoveryPending = false
                    return (.deviceLost, dropped)
                }
                state.armDiscovery()
                return (.deviceReplaced, nil)
            }
            guard state.discoveryRequested, lemurDeviceID != nil, !state.isDiscovering else {
                return (.unchanged, nil)
            }
            state.armDiscovery()
            return (.rediscover, nil)
        }
        // The buffers still queued were enqueued retained and would leak with the
        // queue. Draining is safe only here: no LemurCam device is listed any more,
        // so CMIO has torn down the device's streams and no longer dequeues from
        // this queue, and `enqueue` can't reach it since it left the state above.
        // A replaced device is not drained: the old one may still be listed, and a
        // second thread dequeuing alongside CMIO would corrupt the queue.
        lostResources?.queue.releaseRetainedElements()
        return action
    }
}
