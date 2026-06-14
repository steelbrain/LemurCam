import CoreMedia
import CoreMediaIO
import Foundation
import os

internal typealias SinkSampleBufferHandler = @Sendable (CMSampleBuffer) -> Void

internal final class ExtensionSinkStreamState: Sendable {
    internal struct SubscriptionSnapshot: Sendable {
        let client: SendableRetainedReference<CMIOExtensionClient>
        let generation: UInt64
    }

    private struct State: Sendable {
        var consumeSampleBuffer: SinkSampleBufferHandler?
        var client: SendableRetainedReference<CMIOExtensionClient>?
        var streaming = false
        var generation: UInt64 = 0
        var activeFormatIndex = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var consumeSampleBuffer: SinkSampleBufferHandler? {
        get {
            state.withLock { $0.consumeSampleBuffer }
        }
        set {
            state.withLock {
                $0.consumeSampleBuffer = newValue
            }
        }
    }

    var activeFormatIndex: Int {
        state.withLock { $0.activeFormatIndex }
    }

    func setActiveFormatIndex(_ index: Int) -> Int? {
        state.withLock { state in
            let oldValue = state.activeFormatIndex
            guard index < 1 else {
                return oldValue
            }
            state.activeFormatIndex = index
            return nil
        }
    }

    func setClient(_ client: CMIOExtensionClient) {
        let retainedClient = SendableRetainedReference(client)
        state.withLock {
            $0.client = retainedClient
        }
    }

    func start() {
        state.withLock {
            $0.streaming = true
            $0.generation &+= 1
        }
    }

    func stop() {
        state.withLock {
            $0.streaming = false
            $0.generation &+= 1
        }
    }

    func markDisconnected() {
        stop()
    }

    func subscriptionSnapshot() -> SubscriptionSnapshot? {
        state.withLock { state in
            guard state.streaming, let client = state.client else {
                return nil
            }
            return SubscriptionSnapshot(client: client, generation: state.generation)
        }
    }

    func isCurrent(generation: UInt64) -> Bool {
        state.withLock {
            $0.streaming && $0.generation == generation
        }
    }

    func deliver(_ sampleBuffer: CMSampleBuffer) {
        let handler = state.withLock { $0.consumeSampleBuffer }
        handler?(sampleBuffer)
    }
}
