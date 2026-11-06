import CoreMedia
import CoreMediaIO
import os

internal typealias SinkSampleBufferHandler = @Sendable (CMSampleBuffer) -> Void

/// Lock-protected sink-stream state. The session/generation decisions live in the
/// pure `SinkStreamSession` (Shared/, unit-tested); this type only adds the CMIO
/// client and the frame handler, and makes each check-and-act step atomic.
internal final class ExtensionSinkStreamState: Sendable {
    private struct State: Sendable {
        var consumeSampleBuffer: SinkSampleBufferHandler?
        var client: SendableRetainedReference<CMIOExtensionClient>?
        var session = SinkStreamSession()
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

    func setClient(_ client: CMIOExtensionClient) {
        let retainedClient = SendableRetainedReference(client)
        state.withLock {
            $0.client = retainedClient
        }
    }

    /// Begin a new session; returns the generation its consume requests carry.
    func start() -> UInt64 {
        state.withLock { $0.session.start() }
    }

    func stop() {
        state.withLock { $0.session.stop() }
    }

    /// Stop the session after its consume loop reported a disconnect, only if
    /// `generation` is still live. Returns whether it stopped anything.
    func markDisconnected(ifCurrent generation: UInt64) -> Bool {
        state.withLock { $0.session.disconnect(ifCurrent: generation) }
    }

    /// The client to pull from for a consume request under `generation`, or nil
    /// when that session is no longer live. Checking the generation in the same
    /// lock as reading the client means a loop from an ended session can never
    /// re-arm itself under a newer session's generation.
    func client(forGeneration generation: UInt64) -> SendableRetainedReference<CMIOExtensionClient>? {
        state.withLock { state in
            guard state.session.isCurrent(generation) else { return nil }
            return state.client
        }
    }

    func completionAction(
        generation: UInt64,
        hasBuffer: Bool,
        hasError: Bool,
        frameRate: Int
    ) -> SinkCompletionAction {
        state.withLock {
            $0.session.completionAction(
                generation: generation, hasBuffer: hasBuffer, hasError: hasError, frameRate: frameRate
            )
        }
    }

    func deliver(_ sampleBuffer: CMSampleBuffer) {
        let handler = state.withLock { $0.consumeSampleBuffer }
        handler?(sampleBuffer)
    }
}
