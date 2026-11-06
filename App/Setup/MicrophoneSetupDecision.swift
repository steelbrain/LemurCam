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

/// App-side state the installed-driver check is applied against.
internal struct MicrophoneCheckContext: Equatable {
    var currentStatus: MicrophoneStatus
    /// The user started mic setup and the helper was just approved.
    var autoInstallPending = false
    /// The check follows an install the helper reported as done.
    var verifyingInstall = false
    /// An install through the helper already left an unsealed copy this session.
    var staleHelperSeen = false
    /// `CFBundleVersion` of the driver bundled in this app.
    var bundledVersion: String?
}

/// What to do with an installed-driver check. Pure, so the reply handling
/// (including an unreachable helper) is unit testable without XPC.
internal enum MicrophoneVersionReply: Equatable {
    /// Leave `micStatus` as it is.
    case keepStatus
    /// Show this status.
    case setStatus(MicrophoneStatus)
    /// The helper was just approved mid-setup and no driver is installed yet:
    /// install it now instead of making the user click again.
    case installDriver

    static let unreachableMessage = "Couldn’t reach the microphone helper. Please try again."

    static func decide(_ check: InstalledDriverCheck, context: MicrophoneCheckContext) -> Self {
        guard check.reachable else { return unreachable(currentStatus: context.currentStatus) }
        guard check.version != nil else {
            return context.autoInstallPending ? .installDriver : .setStatus(.notSetUp)
        }
        guard check.sealed else {
            // Still unsealed right after the helper installed a copy: the helper
            // serving us predates sealing (one from before an app update that has
            // not exited). Installing again would only repeat that, so ask for the
            // restart that replaces it.
            if context.verifyingInstall || context.staleHelperSeen { return .setStatus(.needsReboot) }
            return .setStatus(.ready)
        }
        return .setStatus(.ready)
    }

    /// Once the status is known, an unreachable helper is a hiccup, not "not
    /// installed", so keep it. Before that, waiting would leave a spinner with no
    /// action forever; fail so "Try Again" is offered. A later successful query
    /// (poll or reactivation) replaces the failure.
    private static func unreachable(currentStatus: MicrophoneStatus) -> Self {
        currentStatus == .unknown ? .setStatus(.failed(unreachableMessage)) : .keepStatus
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
