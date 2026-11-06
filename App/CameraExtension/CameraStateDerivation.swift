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
    /// `holdingFailure` is true while a failed request's reason is shown and the user
    /// has not acted on it (`FailureHold`): a reply that still finds nothing installed
    /// says nothing the reason doesn't, so the reason stays up.
    static func resolveInstall(
        _ classification: ExtensionInstallClassification,
        isBusy: Bool,
        holdingFailure: Bool
    ) -> InstallResolution {
        switch classification {
        case .notInstalled:
            return isBusy || holdingFailure ? .keepCurrent : .status(.notInstalled)
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

    /// Keeps a failed activation's or repair's reason up through routine refreshes.
    /// The setup window re-queries every 2.5 s and the app re-queries whenever it
    /// becomes active; a reply that still found nothing installed replaced the reason
    /// (a system policy blocked the install, say) with "Required. Enable the camera…"
    /// within seconds. The hold ends on the user's next camera action (Enable or Try
    /// Again, Repair, Re-check Now), whose outcome then shows, or as soon as the status
    /// is anything but the failure (a reply found the extension awaiting approval,
    /// enabled, duplicated, …).
    struct FailureHold: Equatable {
        private(set) var isHolding = false

        /// A request failed; its reason is (about to be) the status.
        mutating func requestFailed() {
            isHolding = true
        }

        /// The user acted on the camera: what their action finds replaces the reason.
        mutating func release() {
            isHolding = false
        }

        /// The status changed. Only a failure keeps the hold.
        mutating func statusChanged(to status: CameraExtensionStatus) {
            if case .failed = status { return }
            isHolding = false
        }
    }

    /// Decides whether the setup coordinator's liveness-poll timeout may act, and
    /// re-arms the poll when it had to wait. While one of our own activation or
    /// deactivation requests is in flight, "installing" is accurate, not stuck (an
    /// activation can take longer than the ~11 s poll budget), so a timeout then
    /// must not prompt an app restart or record the restart marker, which would
    /// escalate to a reboot prompt on the next launch. It is deferred instead, and
    /// once the request has landed with the status still `.installing` (unchanged,
    /// so no status-change callback restarted the poll) a fresh poll is started.
    struct PollTimeoutGate: Equatable {
        private(set) var isDeferred = false

        /// The poll budget ran out. Returns true when the timeout should be
        /// resolved now (prompt restart or escalate); false when it doesn't apply
        /// or was deferred until the in-flight request lands.
        mutating func pollTimedOut(currentStatus: CameraExtensionStatus, isBusy: Bool) -> Bool {
            guard currentStatus == .installing else { return false }
            guard !isBusy else {
                isDeferred = true
                return false
            }
            isDeferred = false
            return true
        }

        /// A request outcome or properties reply was applied. Returns true when the
        /// caller should restart the liveness poll for a deferred timeout.
        mutating func stateSettled(currentStatus: CameraExtensionStatus, isBusy: Bool) -> Bool {
            guard isDeferred, !isBusy else { return false }
            isDeferred = false
            return currentStatus == .installing
        }

        /// The status changed: any status change starts or cancels the poll itself,
        /// so a deferred timeout no longer needs re-arming.
        mutating func statusChanged() {
            isDeferred = false
        }
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
            // A stale version is serving while an old version is staged to uninstall
            // on reboot: macOS deferred the swap to the reboot (see below), so an app
            // restart would only bring the same stale extension back.
            case .appRestartRequired: return rebootPending ? .reboot : .appRestart
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
