/// Setup state of the virtual microphone, derived from the privileged helper's
/// registration state plus whether the audio driver is installed. Collapses the
/// old four-button helper/driver dance into a single "enable" progression.
internal enum MicrophoneStatus: Equatable {
    /// Not yet queried.
    case unknown
    /// Checking again at the user's request ("Try Again" checking first, "Re-check
    /// Now"), from a status already known: shown as checking, not as the first launch.
    case checking
    /// Helper not registered, or registered+enabled but the driver isn't installed.
    case notSetUp
    /// Helper registered but the user must approve it in System Settings.
    case needsApproval
    /// Registering the helper or installing the driver is in progress.
    case installing
    /// Helper enabled and driver installed — the microphone is available.
    case ready
    /// The helper serving the app is one from before an app update that has not
    /// exited (an install through it left a copy not sealed to root, or it identified
    /// itself as one), so it can install no sealed copy. Only a restart replaces it.
    case needsReboot
    /// A setup step failed; the associated string is a user-facing reason.
    case failed(String)
}

/// What the installed-driver check found: whether the privileged helper answered,
/// the installed driver's `CFBundleVersion` (nil when none is installed), whether
/// the installed copy is sealed to root (`sealed` means nothing but root can change
/// it; checked by the app itself, see `AudioDeviceInstaller`), and which helper
/// answered.
internal struct InstalledDriverCheck: Equatable {
    var reachable: Bool
    var version: String?
    var sealed: Bool
    var helper = AudioHelperIdentity.notIdentified

    /// The helper could not be reached, or did not answer in time.
    static let unreachable = Self(reachable: false, version: nil, sealed: false)
}

/// Which privileged helper answered an installed-driver check, told by whether it
/// answers `helperBuild` (see `AudioDeviceInstaller.installedDriver`).
internal enum AudioHelperIdentity: Equatable {
    /// Not reached, or not asked.
    case notIdentified
    /// It answered `helperBuild`: a helper newer than v1.5, which seals the driver it
    /// installs.
    case current
    /// It answered `installedVersion`, but not `helperBuild` (its connection ended, or
    /// no reply in time): a helper from v1.5 or before, which doesn't implement it,
    /// still serving the app after an update. It installs copies not sealed to root,
    /// and only a restart replaces it.
    case stale

    /// From a helper that answered `installedVersion`: its `helperBuild` answer, nil
    /// when it gave none.
    init(helperBuild: String?) {
        self = helperBuild == nil ? .stale : .current
    }
}

/// A driver operation run through the privileged helper.
internal enum MicrophoneDriverOperation: Equatable {
    /// Install or update (reinstall) the bundled driver.
    case install
    /// Remove the installed driver.
    case remove
}

/// How a driver install or removal through the helper ended, as the app saw it.
internal enum MicrophoneOperationResult: Equatable {
    case succeeded
    /// The operation ran and did not finish: the helper answered with this reason
    /// (e.g. "Driver installed but coreaudiod restart failed: …"), or the app had no
    /// driver to send.
    case failed(String)
    /// The helper could not be reached, so whether it ran the operation is unknown.
    case noAnswer(String)

    /// The helper's reply. Its signature is the one every helper since v1.5 answers
    /// with, so an older helper still serving the app is understood the same way.
    init(success: Bool, message: String) {
        self = success ? .succeeded : .failed(message)
    }
}

/// A driver install or removal that did not succeed, while its `.failed` status is
/// up. Decides what "Try Again" does.
internal struct MicrophoneOperationFailure: Equatable {
    var operation: MicrophoneDriverOperation
    /// The helper answered that the operation failed (or the app had no driver to
    /// send it), so it did not finish: the files can be in place with coreaudiod
    /// never restarted. False when the helper never answered (unreachable, or no
    /// reply in time): it may have finished.
    var reportedByHelper: Bool

    /// Whether letting this failure go without a redo (Skip, Re-check Now) leaves an
    /// install unfinished: the helper said it failed, so the copy can be in place with
    /// coreaudiod never restarted, which a check would show as Ready.
    var leavesInstallUnfinished: Bool { reportedByHelper && operation == .install }
}

/// What "Try Again" on a failed microphone status does. Pure, so it is testable
/// without XPC.
internal enum MicrophoneRetry: Equatable {
    /// The helper is not approved: continue setup (register it, or open Login Items).
    case continueSetup
    /// An operation is already running.
    case ignore
    /// Redo the failed operation now. The helper said it did not finish, so a check
    /// could find the bundled driver in place and wrongly call it done.
    case redo(MicrophoneDriverOperation)
    /// Check the installed driver first, and let the check redo the operation only
    /// if it is still needed (`MicrophoneVersionReply`): the helper never answered,
    /// so it may have finished, and every redo restarts coreaudiod, cutting audio in
    /// every app.
    case checkFirst

    static func decide(helperEnabled: Bool, operationRunning: Bool, failure: MicrophoneOperationFailure?) -> Self {
        guard helperEnabled else { return .continueSetup }
        guard !operationRunning else { return .ignore }
        if let failure, failure.reportedByHelper { return .redo(failure.operation) }
        return .checkFirst
    }
}

/// App-side state the installed-driver check is applied against.
internal struct MicrophoneCheckContext: Equatable {
    var currentStatus: MicrophoneStatus
    /// The user started mic setup and the helper was just approved.
    var autoInstallPending = false
    /// "Try Again" is checking first (`MicrophoneRetry.checkFirst`).
    var retrying = false
    /// The install or removal the user last started, until a check shows how it
    /// ended; nil when only a check failed. What a "Try Again" check redoes, if needed.
    var lastOperation: MicrophoneDriverOperation?
    /// The check follows an install the helper reported as done.
    var verifyingInstall = false
    /// A stale helper serves the app (`StaleHelperMarker`): an install through it left
    /// an unsealed copy since the Mac last started, or it identified itself as one.
    var staleHelperSeen = false
    /// `CFBundleVersion` of the driver bundled in this app.
    var bundledVersion: String?
    /// `currentStatus` is why an install or removal failed, and the user has not
    /// acted on it yet (`MicrophoneOperationFailure`).
    var holdingFailure = false
    /// "Try Again" on that failure found the helper no longer approved, and went on
    /// to approving it: the first check that reaches it redoes this operation.
    var redoAfterApproval: MicrophoneOperationFailure?
}

/// What a routine refresh (the app becoming active, the setup window's poll, a
/// Settings page appearing) does with the helper's registration state. Pure, so it
/// is testable without SMAppService.
internal enum MicrophoneRefresh: Equatable {
    /// The helper is approved: check the installed driver.
    case checkDriver
    /// Show this status.
    case setStatus(MicrophoneStatus)
    /// Leave `micStatus` as it is.
    case keepStatus

    /// A running operation's progress stays up, and so does an operation's failure
    /// the user has not acted on: replacing it on the next poll took the reason away
    /// within seconds. No check is sent while an operation runs: the helper answers
    /// it only after the operation, its answer is not applied then, and the
    /// operation is followed by a check of its own.
    static func decide(helper: AudioDeviceInstaller.State, operationRunning: Bool, holdingFailure: Bool) -> Self {
        guard !operationRunning else { return .keepStatus }
        switch helper {
        case .enabled: return .checkDriver
        case .notRegistered, .notFound: return holdingFailure ? .keepStatus : .setStatus(.notSetUp)
        case .requiresApproval: return holdingFailure ? .keepStatus : .setStatus(.needsApproval)
        }
    }
}

/// What to do with an installed-driver check. Pure, so the reply handling
/// (including an unreachable helper) is unit testable without XPC.
internal enum MicrophoneVersionReply: Equatable {
    /// Leave `micStatus` as it is.
    case keepStatus
    /// Show this status.
    case setStatus(MicrophoneStatus)
    /// Install the bundled driver now: the helper was just approved mid-setup and no
    /// driver is installed yet, or "Try Again" after an install found it still needed.
    case installDriver
    /// "Try Again" after a removal found the driver still installed, or must redo it.
    case uninstallDriver

    static let unreachableMessage = "Couldn’t reach the microphone helper. Please try again."

    static func decide(_ check: InstalledDriverCheck, context: MicrophoneCheckContext) -> Self {
        // An operation's failure stays up until the user acts on it (Try Again,
        // Enable, Update, Remove, or moving past the setup step); the check still
        // updates the installed version and seal behind it.
        if context.holdingFailure { return .keepStatus }
        guard check.reachable else { return unreachable(currentStatus: context.currentStatus) }
        // "Try Again" redoes an install or removal the helper reported as failed
        // without asking whether it is still needed (see `MicrophoneRetry`): here
        // when it had to wait for the helper's approval first.
        if let pending = context.redoAfterApproval, pending.reportedByHelper {
            return pending.operation == .install ? .installDriver : .uninstallDriver
        }
        // After one the helper never answered it redoes it only if this check shows
        // it is still needed: each one restarts coreaudiod, cutting audio everywhere.
        let redo = context.redoAfterApproval?.operation ?? (context.retrying ? context.lastOperation : nil)
        return installed(check, redo: redo, context: context)
    }

    /// What a check that reached the helper shows, given the operation it may redo.
    private static func installed(
        _ check: InstalledDriverCheck, redo: MicrophoneDriverOperation?, context: MicrophoneCheckContext
    ) -> Self {
        guard let version = check.version else { return notInstalled(check, redo: redo, context: context) }
        if redo == .remove { return .uninstallDriver }
        guard check.sealed else {
            // Still unsealed right after the helper installed a copy: the helper
            // serving us predates sealing (one from before an app update that has
            // not exited). Installing again would only repeat that, so ask for the
            // restart that replaces it. A helper that identified itself as current
            // seals what it installs: Update (or the redo) goes through it.
            if isStale(check.helper, seen: context.verifyingInstall || context.staleHelperSeen) {
                return .setStatus(.needsReboot)
            }
            return redo == .install ? .installDriver : .setStatus(.ready)
        }
        if redo == .install,
           MicrophoneUpdateReason.reason(installed: version, bundled: context.bundledVersion, sealed: true) != nil {
            return .installDriver
        }
        return .setStatus(.ready)
    }

    /// What a check that reached the helper and found no driver shows.
    private static func notInstalled(
        _ check: InstalledDriverCheck, redo: MicrophoneDriverOperation?, context: MicrophoneCheckContext
    ) -> Self {
        // Redoing a removal never installs, whatever setup started before it.
        if (context.autoInstallPending && redo != .remove) || redo == .install { return .installDriver }
        // A restart asked for (Enable refused because a stale helper serves the app,
        // or an install through it left an unsealed copy) stays asked for while that
        // helper serves the app: "Not set up" would offer Enable again, which is
        // refused until the restart. Never asked for here on its own (the first
        // launch after an update, after a removal): only once the user asked to
        // install.
        if context.currentStatus == .needsReboot, isStale(check.helper, seen: context.staleHelperSeen) {
            return .setStatus(.needsReboot)
        }
        return .setStatus(.notSetUp)
    }

    /// Whether a stale helper answered: it identified itself as one, or it did not
    /// tell and `seen` says one serves the app.
    private static func isStale(_ helper: AudioHelperIdentity, seen: Bool) -> Bool {
        helper == .stale || (helper != .current && seen)
    }

    /// A known status survives an unreachable helper: it is a hiccup, not "not
    /// installed". A spinner with no action (still checking, or an operation waiting
    /// for its result) would stay forever, so fail and offer "Try Again". A later
    /// successful check replaces the failure.
    private static func unreachable(currentStatus: MicrophoneStatus) -> Self {
        switch currentStatus {
        case .unknown, .checking, .installing: return .setStatus(.failed(unreachableMessage))
        case .notSetUp, .needsApproval, .ready, .needsReboot, .failed: return .keepStatus
        }
    }
}

/// When the Settings status card offers "Remove Microphone…". Pure, so it is
/// testable without the view.
internal enum MicrophoneRemoval {
    /// With the microphone working, and while a restart is asked for (an older helper
    /// still serves the app) if a driver is installed: removing goes through that
    /// helper too, and needs no copy sealed to root, so it need not wait for a restart.
    static func isOffered(status: MicrophoneStatus, installedVersion: String?) -> Bool {
        switch status {
        case .ready: return true
        case .needsReboot: return installedVersion != nil
        case .unknown, .checking, .notSetUp, .needsApproval, .installing, .failed: return false
        }
    }
}

/// Why a working microphone should be updated (reinstalled from this app).
internal enum MicrophoneUpdateReason: Equatable {
    /// This app bundles a newer driver.
    case newerVersion
    /// The installed copy is not sealed to root: anything running as the user could
    /// change the driver that coreaudiod loads (every copy installed before the
    /// helper sealed them).
    case unsealed
    /// The last install did not finish: the helper reported it failed (the copy in
    /// place, coreaudiod not restarted, say), and the user moved past the failure
    /// without redoing it. Apps may not be using the copy a check finds.
    case unfinishedInstall

    static func reason(installed: String?, bundled: String?, sealed: Bool, installUnfinished: Bool = false) -> Self? {
        guard let installed else { return nil }
        if installUnfinished { return .unfinishedInstall }
        if !sealed { return .unsealed }
        guard let bundled, ExtensionUpgradeDecision.isUpdateAvailable(installed: installed, bundled: bundled) else {
            return nil
        }
        return .newerVersion
    }
}

/// Microphone status copy shared by the setup window and the Settings status card.
internal enum MicrophoneStatusCopy {
    static let checking = "Checking the microphone\u{2026}"
    static let needsReboot = "An older copy of LemurCam’s audio helper is still running. "
        + "Restart your Mac to finish installing the microphone."
    static let unsealed = "The installed copy can be modified without administrator rights. "
        + "Updating reinstalls it protected and briefly restarts audio."
    static let newerVersion = "A newer version is available — updating briefly restarts audio."
    static let unfinishedInstall = "The last install didn’t finish, so apps may not be using this copy yet. "
        + "Updating installs it again and briefly restarts audio."

    /// The "Remove Microphone…" confirmation's message. While a restart is asked for,
    /// an older helper serves the app and no install goes through it, so the
    /// microphone can be re-enabled only after the restart.
    static func removal(restartAsked: Bool) -> String {
        "This uninstalls the audio component and briefly restarts audio. " + (restartAsked
            ? "You can re-enable it without approving again once you restart your Mac."
            : "You can re-enable it anytime without approving again.")
    }

    /// Why "Update Microphone" is offered.
    static func update(_ reason: MicrophoneUpdateReason) -> String {
        switch reason {
        case .newerVersion: return newerVersion
        case .unsealed: return unsealed
        case .unfinishedInstall: return unfinishedInstall
        }
    }
}
