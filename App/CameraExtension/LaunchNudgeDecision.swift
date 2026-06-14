import Foundation

/// What the proactive launch banner should tell the user, if anything. Kept pure
/// and OS-free so the "should we nudge" policy is unit-testable without AppKit.
///
/// The banner exists because the upgrade-pending restart/reboot states only render
/// in surfaces the user may never open (popover, Settings, Setup). A user who never
/// opens a window after an in-place upgrade would otherwise keep running stale code
/// (or no camera at all) with no signal that a restart is required.
internal enum LaunchNudge: Equatable {
    /// The camera extension updated but LemurCam must relaunch to run the new code.
    case appRestart
    /// The update completes only after a full Mac reboot.
    case reboot
}

/// Pure classifier for the launch banner. The controller layer decides *when* to
/// present (window not already open, not dismissed this session); this decides
/// *whether* the current state warrants a nudge at all.
internal enum LaunchNudgeDecision {
    /// Nudge only for upgrade-pending states the user might otherwise never see —
    /// the app is running stale code (or none) until a restart. Approval/install/
    /// repair states are deliberately excluded: a fresh install isn't a missed
    /// upgrade, and those states already pull the user into guided setup.
    static func evaluate(cameraStatus: CameraExtensionStatus) -> LaunchNudge? {
        switch cameraStatus {
        case .needsAppRestart: return .appRestart
        case .needsReboot: return .reboot
        case .unknown, .notInstalled, .installing, .awaitingApproval,
             .disabled, .ready, .needsRepair, .failed:
            return nil
        }
    }
}
