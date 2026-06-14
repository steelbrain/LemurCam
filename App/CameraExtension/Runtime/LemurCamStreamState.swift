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

    internal enum RetryAction {
        case idle
        case failed
        case discover(attempt: Int)
    }

    internal enum DiscoveryResultAction {
        case alreadyReady
        case retry
        case ready
    }

    private struct State: Sendable {
        var streamResources: CMIOStreamQueueResources?
        var isStreaming = false
        var isStarting = false
        var deviceID: CMIODeviceID?
        var streamID: CMIOStreamID?
        var isReady = false
        var hasConnectedOnce = false
        var setupRetries = 0
        var isDiscovering = false
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

    func resetSetupRetries() {
        state.withLock {
            $0.setupRetries = 0
        }
    }

    func prepareRetry(maxRetries: Int) -> RetryAction {
        state.withLock { state -> RetryAction in
            if state.isReady || state.isDiscovering {
                return .idle
            }
            guard state.setupRetries < maxRetries else {
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
            if state.isReady {
                return .alreadyReady
            }
            guard let result else {
                return .retry
            }
            state.deviceID = result.deviceID
            state.streamID = result.streamID
            state.isReady = true
            return .ready
        }
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
