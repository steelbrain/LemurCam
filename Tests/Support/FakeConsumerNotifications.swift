@testable import LemurCam
import os

/// Stands in for the camera extension's or the audio driver's consumer
/// notifications, which are system-wide: a test that listened to the real ones
/// would hear any LemurCam camera or microphone on the Mac start and stop. `observe` is a `ConsumerObserving` that
/// keeps the handler it is given and returns a registration which, like the real
/// observer, ends when released. `post(active:)` delivers an edge to a live
/// registration's handler, as the real observer does on the main thread.
internal final class FakeConsumerNotifications: Sendable {
    private struct State {
        var handler: (@MainActor @Sendable (Bool) -> Void)?
        var isRegistered = false
    }

    /// Ends the registration when released.
    private final class Registration: Sendable {
        private let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        deinit { onRelease() }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var observe: ConsumerObserving {
        { [state] onChange in
            state.withLock { state in
                state.handler = onChange
                state.isRegistered = true
            }
            return Registration { state.withLock { $0.isRegistered = false } }
        }
    }

    /// Whether a registration `observe` returned is still held.
    var isRegistered: Bool {
        state.withLock { $0.isRegistered }
    }

    @MainActor
    func post(active: Bool) {
        let handler = state.withLock { $0.isRegistered ? $0.handler : nil }
        handler?(active)
    }
}
