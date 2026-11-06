import Foundation

/// What the camera extension's sink stream does with one
/// `consumeSampleBuffer(from:)` completion, once it knows which session the
/// completion belongs to.
internal enum SinkCompletionAction: Equatable {
    /// The completion belongs to a session that `stopStream`/`startStream` has
    /// since ended or replaced. Drop it entirely: don't forward its buffer, don't
    /// report its sequence number, don't re-arm and don't tear anything down.
    /// Acting on it would stop the newer session (on an error) or start a second
    /// consume loop next to the newer session's own (on a re-arm). A buffer it
    /// carries is dropped too: it was pulled for the old session, its sequence
    /// number belongs to that session, and forwarding it could put an older frame
    /// after the new session's first frames. Losing one frame at a session
    /// boundary is not visible.
    case discardStale
    /// The completion belongs to the live session: take the scheduler's action.
    case proceed(SinkConsumeAction)
}

/// Pure, CMIO-free session bookkeeping for the camera extension's sink-stream
/// consume loop (`ExtensionSinkStreamState`). Every `start()` and `stop()` bumps
/// the generation, and each consume request records the generation it was issued
/// under, so completions from an earlier session can be told apart from the live
/// one. Lives in `Shared/` so it is unit-tested through the app module; the
/// extension keeps the CMIO objects.
internal struct SinkStreamSession: Equatable, Sendable {
    private(set) var isStreaming = false
    private(set) var generation: UInt64 = 0

    /// `startStream`: begin a new session and return its generation. Completions
    /// still outstanding from any earlier session become stale.
    @discardableResult
    mutating func start() -> UInt64 {
        isStreaming = true
        generation &+= 1
        return generation
    }

    /// `stopStream`: end the current session. Outstanding completions become stale.
    mutating func stop() {
        isStreaming = false
        generation &+= 1
    }

    /// Whether `candidate` is the generation of the session that is streaming now.
    func isCurrent(_ candidate: UInt64) -> Bool {
        isStreaming && generation == candidate
    }

    /// End the session because its consume loop reported that the client went
    /// away, but only if `candidate` is still the live session. Returns whether it
    /// ended anything; an error from an earlier session must not stop a newer one.
    mutating func disconnect(ifCurrent candidate: UInt64) -> Bool {
        guard isCurrent(candidate) else { return false }
        stop()
        return true
    }

    /// Map a completion issued under `candidate` to its action. Stale completions
    /// are discarded whatever they carry; live ones follow `SinkConsumeScheduler`.
    func completionAction(
        generation candidate: UInt64,
        hasBuffer: Bool,
        hasError: Bool,
        frameRate: Int
    ) -> SinkCompletionAction {
        guard isCurrent(candidate) else { return .discardStale }
        return .proceed(SinkConsumeScheduler.action(hasBuffer: hasBuffer, hasError: hasError, frameRate: frameRate))
    }
}
