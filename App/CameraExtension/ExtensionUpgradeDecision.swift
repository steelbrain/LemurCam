import Foundation

/// Ground-truth upgrade state of the camera system extension, derived by
/// comparing the version the app *ships* (the embedded extension's
/// `CFBundleVersion`) against the version the *running* extension stamped into
/// the app group, plus whether macOS said the last activation needs a reboot.
///
/// This exists because neither `OSSystemExtensionRequest.propertiesRequest` nor
/// the CoreMediaIO liveness check reveals which version is actually executing:
/// after an in-place upgrade macOS can keep the old extension resident (until
/// the consumer releases it or the Mac reboots) and still report the activation
/// `.completed`. Without this check the app shows "Ready" while stale code serves
/// frames — the root of the "I didn't know I had to restart" reports.
internal enum ExtensionUpgradeState: Equatable {
    /// The running version matches the bundled version — the shipped code is live.
    case upToDate
    /// A newer version is installed but not yet running. Relaunching the app
    /// re-activates and lets macOS swap in the new extension.
    case appRestartRequired
    /// macOS reported the swap completes only after a full Mac reboot.
    case rebootRequired
    /// The running version isn't known yet (the extension hasn't stamped — e.g. a
    /// pre-handshake build, or it isn't running). Don't raise a false alarm; the
    /// caller falls back to the enabled/liveness signals.
    case unknown
}

/// Pure, OS-free classifier for `ExtensionUpgradeState`. Kept separate from
/// `CameraExtensionController` so the upgrade logic is unit-testable without
/// SystemExtensions or a live install.
internal enum ExtensionUpgradeDecision {
    /// - Parameters:
    ///   - bundled: `CFBundleVersion` of the extension embedded in this app.
    ///   - running: version the live extension published into the app group, if any.
    ///   - rebootFlaggedByOS: macOS returned `.willCompleteAfterReboot` for the
    ///     most recent activation request.
    static func evaluate(
        bundled: String?,
        running: String?,
        rebootFlaggedByOS: Bool
    ) -> ExtensionUpgradeState {
        guard let bundled, !bundled.isEmpty else { return .unknown }
        // If the live version is the same as — or newer than — what we ship, the
        // swap is done; even if an earlier activation once flagged a reboot, it's
        // now stale. A *newer* running version occurs with a duplicate/older app
        // copy or a downgrade: relaunching this app can't replace a newer resident
        // extension, so treating it as up-to-date avoids an unfixable restart loop.
        if let running, !running.isEmpty {
            switch compareVersions(running, bundled) {
            case .orderedSame, .orderedDescending: return .upToDate
            case .orderedAscending: break // running is older → upgrade pending
            case nil: if running == bundled { return .upToDate } // unparseable: exact match only
            }
        }
        // Not yet matching: a genuine reboot requirement wins over an app restart.
        if rebootFlaggedByOS { return .rebootRequired }
        // Extension hasn't reported a version: don't guess an upgrade is pending.
        guard let running, !running.isEmpty else { return .unknown }
        return .appRestartRequired
    }

    /// Compares two `CFBundleVersion` strings numerically, component by component
    /// (dot-separated, missing trailing components treated as 0). Returns `nil` if
    /// either side has a non-numeric component, so the caller can fall back to exact
    /// string equality rather than mis-ordering an unparseable version.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        let lhsParts = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let rhsParts = rhs.split(separator: ".", omittingEmptySubsequences: false)
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let lhsPart = index < lhsParts.count ? lhsParts[index] : "0"
            let rhsPart = index < rhsParts.count ? rhsParts[index] : "0"
            guard let lhsNum = Int(lhsPart), let rhsNum = Int(rhsPart) else { return nil }
            if lhsNum != rhsNum { return lhsNum < rhsNum ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Whether the app bundles a strictly newer component than the one installed —
    /// i.e. an update is genuinely available. Used for the audio driver's "Update
    /// available" prompt; mirrors the camera handshake's honesty so a *newer*
    /// installed version (a duplicate/older app copy, or a downgrade) never shows a
    /// perpetual "update available". Unparseable versions fall back to exact
    /// inequality, the safe (update-offering) direction.
    static func isUpdateAvailable(installed: String, bundled: String) -> Bool {
        switch compareVersions(installed, bundled) {
        case .orderedAscending: return true // bundled is newer than installed
        case .orderedSame, .orderedDescending: return false
        case nil: return installed != bundled
        }
    }

    /// Escalate an unresolved app-restart to a full reboot. If we already asked the
    /// user to relaunch the app for this exact bundled version (in a prior launch)
    /// and the running version is *still* stale, an app restart isn't enough —
    /// macOS deferred the swap (the old extension is still in use, or the update
    /// genuinely needs a reboot it didn't flag). A Mac restart is the reliable fix.
    static func escalateIfStuck(
        base: ExtensionUpgradeState,
        restartAlreadyTriedForThisVersion: Bool
    ) -> ExtensionUpgradeState {
        if base == .appRestartRequired, restartAlreadyTriedForThisVersion {
            return .rebootRequired
        }
        return base
    }

    /// Classify the install topology from a count summary of a `propertiesRequest`
    /// reply. Pure and OS-free (no `OSSystemExtensionProperties`), so the policy is
    /// unit-testable; the controller layers activation progress on top.
    static func classifyInstall(_ summary: ExtensionPropertiesSummary) -> ExtensionInstallClassification {
        if summary.total == 0 { return .notInstalled }
        if summary.awaitingApproval > 0 { return .awaitingApproval }
        // More than one version that doesn't reduce to exactly one healthy enabled
        // version is the zombie/duplicate state repair fixes. Exactly one enabled
        // among several (old enabled + new staged for reboot, or old enabled + an
        // uninstalling copy) is the normal upgrade path — let the enabled route and
        // the version handshake handle it.
        if summary.total > 1, summary.enabledActive != 1 { return .multipleVersions }
        if summary.enabledActive >= 1 { return .enabled }
        return .disabled
    }
}

/// Count summary of an `OSSystemExtensionRequest.propertiesRequest` result,
/// reduced to plain integers so install classification is testable without
/// constructing `OSSystemExtensionProperties`.
internal struct ExtensionPropertiesSummary: Equatable {
    let total: Int
    let awaitingApproval: Int
    /// Versions that are enabled and not currently uninstalling.
    let enabledActive: Int
}

/// Coarse install topology of the camera extension, independent of activation
/// progress (which the controller layers on).
internal enum ExtensionInstallClassification: Equatable {
    case notInstalled
    case awaitingApproval
    /// More than one version present that doesn't reduce to a single healthy
    /// enabled version — orphaned or conflicting duplicates a repair collapses.
    case multipleVersions
    case enabled
    /// Installed but not enabled (user-disabled or uninstalling).
    case disabled
}
