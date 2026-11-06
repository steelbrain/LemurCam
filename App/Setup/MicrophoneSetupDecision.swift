import Foundation

/// What the installed-driver check found: whether the privileged helper answered,
/// the installed driver's `CFBundleVersion` (nil when none is installed), and
/// whether the installed copy is sealed to root (`sealed` means nothing but root
/// can change it; checked by the app itself, see `AudioDeviceInstaller`).
internal struct InstalledDriverCheck: Equatable {
    var reachable: Bool
    var version: String?
    var sealed: Bool

    /// The helper could not be reached, or did not answer in time.
    static let unreachable = Self(reachable: false, version: nil, sealed: false)
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
    /// An install through the helper already left an unsealed copy since the Mac
    /// last started (`StaleHelperMarker`).
    var staleHelperSeen = false
    /// `CFBundleVersion` of the driver bundled in this app.
    var bundledVersion: String?
    /// `currentStatus` is why an install or removal failed, and the user has not
    /// acted on it yet (`MicrophoneOperationFailure`).
    var holdingFailure = false
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
    /// driver is installed yet, or "Try Again" after an install the helper never
    /// answered found it still needed.
    case installDriver
    /// "Try Again" after a removal the helper never answered found the driver still
    /// installed.
    case uninstallDriver

    static let unreachableMessage = "Couldn’t reach the microphone helper. Please try again."

    static func decide(_ check: InstalledDriverCheck, context: MicrophoneCheckContext) -> Self {
        // An operation's failure stays up until the user acts on it (Try Again,
        // Enable, Update, Remove, or moving past the setup step); the check still
        // updates the installed version and seal behind it.
        if context.holdingFailure { return .keepStatus }
        guard check.reachable else { return unreachable(currentStatus: context.currentStatus) }
        // "Try Again" after an install or removal the helper never answered redoes it
        // only if this check shows it is still needed: each one restarts coreaudiod,
        // cutting audio everywhere. (One the helper reported as failed is redone
        // without a check; see `MicrophoneRetry`.)
        let redo = context.retrying ? context.lastOperation : nil
        guard let version = check.version else {
            if context.autoInstallPending || redo == .install { return .installDriver }
            return .setStatus(.notSetUp)
        }
        if redo == .remove { return .uninstallDriver }
        guard check.sealed else {
            // Still unsealed right after the helper installed a copy: the helper
            // serving us predates sealing (one from before an app update that has
            // not exited). Installing again would only repeat that, so ask for the
            // restart that replaces it.
            if context.verifyingInstall || context.staleHelperSeen { return .setStatus(.needsReboot) }
            return redo == .install ? .installDriver : .setStatus(.ready)
        }
        if redo == .install,
           MicrophoneUpdateReason.reason(installed: version, bundled: context.bundledVersion, sealed: true) != nil {
            return .installDriver
        }
        return .setStatus(.ready)
    }

    /// A known status survives an unreachable helper: it is a hiccup, not "not
    /// installed". A spinner with no action (still checking, or an operation waiting
    /// for its result) would stay forever, so fail and offer "Try Again". A later
    /// successful check replaces the failure.
    private static func unreachable(currentStatus: MicrophoneStatus) -> Self {
        switch currentStatus {
        case .unknown, .installing: return .setStatus(.failed(unreachableMessage))
        case .notSetUp, .needsApproval, .ready, .needsReboot, .failed: return .keepStatus
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

    static func reason(installed: String?, bundled: String?, sealed: Bool) -> Self? {
        guard let installed else { return nil }
        if !sealed { return .unsealed }
        guard let bundled, ExtensionUpgradeDecision.isUpdateAvailable(installed: installed, bundled: bundled) else {
            return nil
        }
        return .newerVersion
    }
}

/// Microphone status copy shared by the setup window and the Settings status card.
internal enum MicrophoneStatusCopy {
    static let needsReboot = "An older copy of LemurCam’s audio helper is still running. "
        + "Restart your Mac to finish installing the microphone."
    static let unsealed = "The installed copy can be modified without administrator rights. "
        + "Updating reinstalls it protected and briefly restarts audio."
}
