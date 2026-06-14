import Foundation

/// Pure state-machine glue for `CameraExtensionController`: turns the OS-reported
/// install topology and the version handshake into the controller's status, with no
/// SystemExtensions / CoreMediaIO dependency. The load-bearing transitions — the
/// liveness gate (never `.ready` while stale code runs), the mismatch/escalation
/// mapping, and the mid-request race guards — live here so they're unit-testable
/// instead of buried in delegate callbacks.
internal enum CameraStateDerivation {

    /// How to resolve a `propertiesRequest` classification into a status.
    enum InstallResolution: Equatable {
        /// Set this status directly.
        case status(CameraExtensionStatus)
        /// Enabled — run the liveness/version derivation (`deriveEnabledState`).
        case deriveEnabled
        /// A racing reply arrived while our own request is in flight; leave the
        /// current status untouched rather than downgrade it mid-activation.
        case keepCurrent
    }

    /// Map the install topology to a resolution. `isBusy` is true while one of our
    /// own activation/deactivation requests is in flight — the empty/duplicate
    /// classifications are then transient and must not clobber the in-flight state.
    static func resolveInstall(
        _ classification: ExtensionInstallClassification,
        isBusy: Bool
    ) -> InstallResolution {
        switch classification {
        case .notInstalled:
            return isBusy ? .keepCurrent : .status(.notInstalled)
        case .awaitingApproval:
            return .status(.awaitingApproval)
        case .multipleVersions:
            return isBusy ? .keepCurrent : .status(.needsRepair)
        case .enabled:
            return .deriveEnabled
        case .disabled:
            // Installed but switched off by the user, or uninstalling. Surface a
            // distinct "disabled" state (honest "re-enable" copy, not "approve"),
            // or installing while our own request is mid-flight.
            return .status(isBusy ? .installing : .disabled)
        }
    }

    /// Outcome once the extension reports enabled. Pure mapping of liveness + the
    /// version handshake to a status decision and its persistence side-effects.
    enum EnabledOutcome: Equatable {
        /// Still settling right after activation: show installing and let the one-shot
        /// liveness poll decide. Only reached from a non-committed status.
        case installing
        /// Enabled but not live, and the status is already a committed post-install
        /// decision (`ready`/`needsAppRestart`/`needsReboot`). A periodic refresh must
        /// NOT bounce it back to installing — that is what made the wizard oscillate
        /// installing↔needs-restart on its own. Leave the status untouched.
        case keepCurrent
        /// Shipped version is live: clear the restart marker + reboot flag, go ready.
        case ready
        /// A stale running version: record the restart marker, prompt an app restart.
        case appRestart
        /// Escalated (a prior app restart didn't take) or OS-flagged: prompt a reboot.
        case reboot
    }

    /// What to do when the liveness poll budget is exhausted while the extension is
    /// enabled but the CMIO device never went live.
    enum PollTimeoutOutcome: Equatable {
        /// First time: prompt one app restart — it often makes a freshly-registered
        /// device visible to a process that connected before it existed.
        case promptRestart
        /// A restart was already tried and the device is *still* absent (not in this
        /// process, nor system-wide for other apps) → an app restart isn't enough;
        /// escalate to a Mac reboot rather than loop on restart or fake readiness.
        case escalateReboot
    }

    static func resolvePollTimeout(restartAlreadyTried: Bool) -> PollTimeoutOutcome {
        restartAlreadyTried ? .escalateReboot : .promptRestart
    }

    /// Map liveness + the (already-resolved) version handshake to a status outcome.
    /// The caller computes `upgradeState` from `ExtensionUpgradeDecision.evaluate`
    /// + `escalateIfStuck` (both tested separately), so the version inputs stay
    /// behind the liveness gate. `currentStatus` is consulted so a periodic refresh
    /// can't revert a committed post-install decision back to installing.
    static func deriveEnabledState(
        isLive: Bool,
        currentStatus: CameraExtensionStatus,
        upgradeState: ExtensionUpgradeState,
        rebootPending: Bool
    ) -> EnabledOutcome {
        if isLive {
            switch upgradeState {
            case .upToDate, .unknown: return .ready
            case .appRestartRequired: return .appRestart
            case .rebootRequired: return .reboot
            }
        }
        // Enabled but the device isn't live. If an old version is staged to uninstall
        // on reboot, macOS has deferred the whole swap until then — relaunching the
        // app can't help, so go straight to reboot rather than the app-restart cycle.
        // (macOS does NOT reliably report this via `.willCompleteAfterReboot`; the
        // properties reply is the ground truth — confirmed on-device.)
        if rebootPending { return .reboot }
        // Otherwise it's the in-process visibility lag: the device often won't appear
        // until the app relaunches. Once we've committed a post-install decision (or
        // confirmed ready), a refresh must leave it alone rather than flap back to
        // installing.
        switch currentStatus {
        case .ready, .needsAppRestart, .needsReboot: return .keepCurrent
        default: return .installing
        }
    }
}
