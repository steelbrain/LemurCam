import Foundation

/// Pure rule for *when* the launch banner may appear (`LaunchNudgeDecision` decides
/// *whether* the camera state warrants one). Kept out of `AppDelegate` so the
/// gating is unit testable without AppKit.
internal enum LaunchNudgeGate {
    /// - Parameters:
    ///   - hasFinishedLaunching: false while `applicationDidFinishLaunching` runs.
    ///     `setupCoordinator.start()` can report a status change before launch opens
    ///     the setup window, so the banner waits for launch to finish rather than
    ///     flash ahead of the wizard.
    ///   - setupWindowOpen: guided setup is showing and owns the same restart prompt.
    ///   - settingsWindowOpen: Settings is showing and owns the same restart prompt.
    /// - Returns: whether the banner may be shown or refreshed. A pending but
    ///   dismissed ("Set Up Later") setup step does not block it, so a later
    ///   upgrade-pending state in the same session still prompts.
    static func canPresent(hasFinishedLaunching: Bool, setupWindowOpen: Bool, settingsWindowOpen: Bool) -> Bool {
        hasFinishedLaunching && !setupWindowOpen && !settingsWindowOpen
    }
}
