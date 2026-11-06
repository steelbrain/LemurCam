import Foundation

/// Ends the privileged helper once it has been idle for a grace period: no XPC
/// connection open and no operation running. The LaunchDaemon is launched on demand
/// through its Mach service (no `KeepAlive`, no `RunAtLoad`), so launchd starts it
/// again, from the binary inside the app bundle as it is now, for the next request.
/// A helper that never exited kept serving with its old code after an app update
/// until the Mac restarted.
///
/// The grace period keeps the helper alive across a burst of requests and makes it
/// outlive launchd's spawn throttle (10 s by default), so a relaunch is never
/// delayed. Scheduling and exiting are injected so the logic is unit testable;
/// compiled into the app only for the tests.
internal final class HelperIdleExit: @unchecked Sendable {
    typealias Schedule = @Sendable (_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) -> Void

    /// How long the helper stays up with no connection open and no operation running.
    static let defaultGrace: TimeInterval = 15

    /// One open connection or running operation; `end()` it exactly when it is over.
    /// Ending twice counts once.
    final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: HelperIdleExit?

        init(owner: HelperIdleExit) {
            self.owner = owner
        }

        func end() {
            let ending = lock.withLock { () -> HelperIdleExit? in
                defer { owner = nil }
                return owner
            }
            ending?.activityEnded()
        }
    }

    private let lock = NSLock()
    private let grace: TimeInterval
    private let schedule: Schedule
    private let exit: @Sendable () -> Void
    private var active = 0
    /// Bumped on every change, so only the latest idle timer can fire.
    private var generation = 0
    private var exiting = false

    init(grace: TimeInterval, schedule: @escaping Schedule, exit: @escaping @Sendable () -> Void) {
        self.grace = grace
        self.schedule = schedule
        self.exit = exit
    }

    /// Arm the idle timer at launch, so a launch no request follows still ends.
    func start() {
        lock.withLock { armIfIdle() }
    }

    /// Record a new connection or operation. Nil once the helper has decided to
    /// exit: the caller should refuse the work (the client sees the connection fail
    /// and retries against a fresh launch).
    func begin() -> Activity? {
        lock.withLock {
            guard !exiting else { return nil }
            active += 1
            generation += 1
            return Activity(owner: self)
        }
    }

    private func activityEnded() {
        lock.withLock {
            active = max(0, active - 1)
            armIfIdle()
        }
    }

    /// Caller holds `lock`.
    private func armIfIdle() {
        generation += 1
        guard active == 0, !exiting else { return }
        let armed = generation
        schedule(grace) { [weak self] in self?.fire(armed) }
    }

    private func fire(_ armed: Int) {
        let shouldExit = lock.withLock { () -> Bool in
            guard !exiting, active == 0, armed == generation else { return false }
            exiting = true
            return true
        }
        if shouldExit { exit() }
    }
}
