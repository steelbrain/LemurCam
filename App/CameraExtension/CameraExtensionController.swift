import Foundation
import os
import SystemExtensions

/// Real, queryable state of the LemurCam camera system extension. Replaces the
/// old "assume running unless a hard failure fired" inference with ground truth
/// from `OSSystemExtensionRequest.propertiesRequest` plus a CoreMediaIO liveness
/// check, so the UI can distinguish "needs approval" from "running" from "failed".
internal enum CameraExtensionStatus: Equatable {
    /// Not yet queried.
    case unknown
    /// No extension is installed for our identifier.
    case notInstalled
    /// An activation request is in flight (installing or finishing up).
    case installing
    /// Installed but the user must approve it in System Settings.
    case awaitingApproval
    /// Installed but switched off by the user (or mid-uninstall): present but not
    /// enabled. Distinct from `awaitingApproval` — the user already approved it once
    /// and later turned it off, so the copy is "re-enable", not "approve".
    case disabled
    /// Update applied but a full Mac reboot is required before it runs (macOS
    /// reported `.willCompleteAfterReboot`, e.g. when replacing a resident version).
    case needsReboot
    /// Enabled, but LemurCam must relaunch to pick up the now-live virtual camera
    /// device — the app connected to CoreMediaIO before the device existed. Only
    /// the app needs restarting, not the Mac.
    case needsAppRestart
    /// Enabled and the virtual camera device is live and selectable.
    case ready
    /// More than one extension version is installed and they don't reduce to a
    /// single healthy enabled version (orphaned or conflicting duplicates). A
    /// one-click repair collapses them back to the current version.
    case needsRepair
    /// Activation failed; the associated string is a user-facing reason.
    case failed(String)
}

/// Owns activation and state queries for the camera system extension. A single
/// delegate handles both `activationRequest` (to install/update) and
/// `propertiesRequest` (to read installed/enabled/approval state). All requests
/// are submitted on `.main`, so `status` mutates and `onStatusChange` fires on
/// the main thread. Not actor-isolated to keep the delegate conformance simple;
/// callers drive it from the main thread.
internal final class CameraExtensionController: NSObject {
    /// Latest known status. Fires `onStatusChange` on change (main thread).
    private(set) var status: CameraExtensionStatus = .unknown {
        didSet {
            guard status != oldValue else { return }
            Log.app.info("Camera extension status: \(String(describing: oldValue)) → \(String(describing: self.status))")
            onStatusChange?(status)
        }
    }

    /// Called on the main thread whenever `status` changes. Owners that capture
    /// `self` in this closure must use `[weak self]` to avoid a retain cycle
    /// (owner → controller → closure → owner).
    var onStatusChange: ((CameraExtensionStatus) -> Void)?

    /// The in-flight activation request, if any. Tracked by reference so callbacks
    /// can tell an activation result apart from a properties-query result (both
    /// share this delegate) and so a racing empty `propertiesRequest` reply does
    /// not clobber an `installing`/`awaitingApproval` state mid-activation.
    private var activationRequest: OSSystemExtensionRequest?

    private var isActivating: Bool { activationRequest != nil }

    /// The in-flight deactivation request during a repair, if any. Tracked so the
    /// delegate can tell it apart from an activation and re-activate when it lands.
    private var deactivationRequest: OSSystemExtensionRequest?

    /// Set while a repair's reactivation is in flight. When that activation lands we
    /// re-query so the duplicate-count check (`classifyInstall`) runs and a partial
    /// dedupe is caught, instead of resolving via liveness alone and flashing `.ready`.
    private var repairReactivationPending = false

    /// A SystemExtensions request (activate or deactivate) is in flight. Used to
    /// suppress redundant/racy properties queries and transient state downgrades.
    private var isBusy: Bool { activationRequest != nil || deactivationRequest != nil }

    /// True once macOS reported an activation completes only after a Mac reboot.
    private var rebootFlagged = false

    /// True when a `propertiesRequest` shows an older version staged to uninstall on
    /// reboot (`isUninstalling`) — macOS has deferred the swap until reboot, so the
    /// new version isn't actually live yet. Ground truth for the reboot prompt, since
    /// the activation result doesn't reliably report `.willCompleteAfterReboot`.
    private var rebootPending = false

    /// CFBundleVersion of the extension embedded in this app; constant per launch.
    private lazy var bundledExtensionVersion: String? = Self.readBundledExtensionVersion()

    /// Persisted marker driving the stuck-app-restart → reboot escalation. Snapshots
    /// the prior launch's value at init; see `applyEnabledState`.
    private let restartMarker: CameraRestartMarker

    /// Live CMIO device-list listener: re-derives status the moment our virtual
    /// camera registers, so enablement converges to `ready` without waiting out the
    /// poll or prompting an app restart. Held for the controller's lifetime.
    private var deviceObserver: CMIODeviceListObserver?

    init(defaults: UserDefaults = .standard) {
        self.restartMarker = CameraRestartMarker(defaults: defaults)
        super.init()
        deviceObserver = CMIODeviceListObserver(queue: .main) { [weak self] in
            // The CMIO device set changed — our camera may have just appeared (or
            // gone away). Re-query so we converge without the poll or a relaunch.
            // refreshStatus is a no-op while a request is in flight (isBusy guard).
            self?.refreshStatus()
        }
    }

    /// Submit an activation request. Idempotent: if the extension is already
    /// installed and current, macOS either completes quickly or our replacement
    /// delegate returns `.cancel` (surfaced as `requestCanceled`), and both paths
    /// resolve to the real enabled/live state.
    func activate() {
        switch status {
        case .unknown, .notInstalled, .failed, .disabled:
            status = .installing
        case .installing, .awaitingApproval, .needsReboot, .needsAppRestart, .ready, .needsRepair:
            break
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: LemurCamConfig.cameraExtensionID,
            queue: .main
        )
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Collapse a duplicate/zombie install to a single current version: deactivate
    /// every installed copy, then re-activate the one this app ships. Surfaced as
    /// the one-click Repair action when `status == .needsRepair`.
    func repair() {
        // Don't start a repair while any request is already in flight — a
        // deactivation racing a concurrent activation would fight over the install.
        guard !isBusy else { return }
        Log.app.info("Repairing camera extension: deactivating all installed versions")
        status = .installing
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: LemurCamConfig.cameraExtensionID,
            queue: .main
        )
        request.delegate = self
        deactivationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Query the authoritative installed/enabled/approval state. Safe to call
    /// repeatedly — on launch, on app reactivation, while a setup UI is open, and
    /// after user actions — to converge on the true state.
    func refreshStatus() {
        // Don't submit a properties request while an activation or deactivation is
        // in flight: a same-identifier properties request can supersede the request,
        // and on a fresh install the activation is the only thing that performs the
        // install and raises the approval prompt. The pending request's own
        // callbacks report the state, so a refresh would be redundant here anyway.
        guard !isBusy else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: LemurCamConfig.cameraExtensionID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - State Derivation

    /// The extension is enabled; report `ready` only once the CMIO device is
    /// actually live. Otherwise stay `installing` and let the caller re-poll —
    /// the device can take a moment to register after enablement.
    private func applyEnabledState() {
        // The liveness gate, version handshake, and escalation live in the pure
        // `CameraStateDerivation` (unit-tested); this just applies the outcome and
        // its persistence side-effects.
        let upgradeState = ExtensionUpgradeDecision.escalateIfStuck(
            base: ExtensionUpgradeDecision.evaluate(
                bundled: bundledExtensionVersion,
                running: LemurCamConfig.runningExtensionVersion,
                rebootFlaggedByOS: rebootFlagged
            ),
            restartAlreadyTriedForThisVersion: restartMarker.wasRestartAlreadyTried(
                forBundled: bundledExtensionVersion
            )
        )
        switch CameraStateDerivation.deriveEnabledState(
            isLive: CoreMediaIOUtil.isLemurCameraLive(),
            currentStatus: status,
            upgradeState: upgradeState,
            rebootPending: rebootPending
        ) {
        case .installing:
            // Enabled but the CMIO device hasn't registered yet, and we haven't
            // committed a decision: settle as installing and let the one-shot poll act.
            status = .installing
        case .keepCurrent:
            // A committed decision (or confirmed-ready) stays put — a periodic refresh
            // must not bounce it back to installing (the self-driving oscillation).
            break
        case .ready:
            restartMarker.clear()
            rebootFlagged = false
            status = .ready
        case .appRestart:
            restartMarker.record(version: bundledExtensionVersion)
            status = .needsAppRestart
        case .reboot:
            status = .needsReboot
        }
    }

    /// Called by the setup coordinator when its liveness poll budget is exhausted
    /// while the extension is enabled but the CMIO device never went live. Routed
    /// through the restart marker so it doesn't loop: prompt one app restart, and if
    /// that already happened and the device is *still* absent, escalate to a reboot
    /// (mirrors `escalateIfStuck`). Never fakes `.ready` — bug reports showed the
    /// device can be genuinely absent for all apps, not just this process.
    func resolvePollTimeout() {
        guard status == .installing else { return }
        switch CameraStateDerivation.resolvePollTimeout(
            restartAlreadyTried: restartMarker.wasRestartAlreadyTried(forBundled: bundledExtensionVersion)
        ) {
        case .promptRestart:
            Log.app.info("Camera enabled but device not live after poll budget; prompting app restart")
            restartMarker.record(version: bundledExtensionVersion)
            status = .needsAppRestart
        case .escalateReboot:
            Log.app.warning("Camera device still not live after an app restart; escalating to reboot")
            status = .needsReboot
        }
    }

    /// Resolve a completed/canceled activation into the enabled state, then — if it
    /// was a repair's reactivation — re-query once so the duplicate-count check runs
    /// and a lingering duplicate re-surfaces as `.needsRepair` rather than `.ready`.
    private func finishActivation() {
        applyEnabledState()
        if repairReactivationPending {
            repairReactivationPending = false
            refreshStatus()
        }
    }

    private static func readBundledExtensionVersion() -> String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(LemurCamConfig.cameraExtensionID).systemextension", isDirectory: true)
            .appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: url),
              let version = info["CFBundleVersion"] as? String else { return nil }
        return version
    }

    private func applyProperties(_ properties: [OSSystemExtensionProperties]) {
        let summary = ExtensionPropertiesSummary(
            total: properties.count,
            awaitingApproval: properties.filter { $0.isAwaitingUserApproval }.count,
            enabledActive: properties.filter { $0.isEnabled && !$0.isUninstalling }.count
        )
        // An older version "waiting to uninstall on reboot" surfaces as isUninstalling;
        // its presence means the swap completes only after a reboot (see applyEnabledState).
        rebootPending = properties.contains { $0.isUninstalling }
        Log.app.info(
            "Camera properties: total=\(summary.total) enabled=\(summary.enabledActive) "
            + "awaiting=\(summary.awaitingApproval) rebootPending=\(self.rebootPending)"
        )
        switch CameraStateDerivation.resolveInstall(
            ExtensionUpgradeDecision.classifyInstall(summary), isBusy: isBusy
        ) {
        case .status(let resolved):
            status = resolved
        case .deriveEnabled:
            applyEnabledState()
        case .keepCurrent:
            break
        }
    }

    private static func message(for error: NSError) -> String {
        guard error.domain == OSSystemExtensionErrorDomain,
              let code = OSSystemExtensionError.Code(rawValue: error.code) else {
            return error.localizedDescription
        }
        switch code {
        case .unsupportedParentBundleLocation:
            return "LemurCam must be in the Applications folder to install its camera extension."
        case .forbiddenBySystemPolicy:
            return "Installation was blocked by a system policy (such as MDM management)."
        case .codeSignatureInvalid, .validationFailed:
            return "The camera extension failed code-signature validation."
        case .missingEntitlement:
            return "The camera extension is missing a required entitlement."
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension CameraExtensionController: OSSystemExtensionRequestDelegate {
    func request(_: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        if existing.bundleVersion == ext.bundleVersion {
            Log.app.info("Camera extension already up to date (v\(existing.bundleVersion))")
            return .cancel
        }
        Log.app.info("Updating camera extension: v\(existing.bundleVersion) → v\(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        Log.app.info("Camera extension needs user approval in System Settings")
        status = .awaitingApproval
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        // A repair's deactivation finished — reinstall the single current version.
        if request === deactivationRequest {
            deactivationRequest = nil
            repairReactivationPending = true
            Log.app.info("Camera extension deactivated for repair; reinstalling current version")
            activate()
            return
        }
        // Only activation requests resolve here; properties replies use foundProperties.
        guard request === activationRequest else { return }
        activationRequest = nil
        switch result {
        case .completed:
            Log.app.info("Camera extension activation completed")
            finishActivation()
        case .willCompleteAfterReboot:
            Log.app.warning("Camera extension update requires reboot")
            rebootFlagged = true
            repairReactivationPending = false
            status = .needsReboot
        @unknown default:
            Log.app.warning("Unknown activation result: \(result.rawValue)")
            repairReactivationPending = false
            refreshStatus()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        let isActivation = request === activationRequest
        let isDeactivation = request === deactivationRequest
        if isActivation { activationRequest = nil }
        if isDeactivation { deactivationRequest = nil }

        if nsError.domain == OSSystemExtensionErrorDomain {
            if nsError.code == OSSystemExtensionError.requestCanceled.rawValue {
                // We returned .cancel because versions matched (activation only) —
                // the extension is already installed.
                Log.app.info("Camera extension already installed (request canceled)")
                if isActivation { finishActivation() }
                return
            }
            if nsError.code == OSSystemExtensionError.requestSuperseded.rawValue {
                // Another request replaced this one; not a real failure. Re-query so
                // the state still converges even if the original activation is lost.
                // The re-query itself runs the count check, so the repair is verified.
                Log.app.info("Camera extension request superseded; re-querying state")
                repairReactivationPending = false
                refreshStatus()
                return
            }
        }

        if isActivation {
            Log.app.error("Camera extension activation failed: \(error.localizedDescription)")
            repairReactivationPending = false
            status = .failed(Self.message(for: nsError))
        } else if isDeactivation {
            Log.app.error("Camera extension repair failed: \(error.localizedDescription)")
            status = .failed(Self.message(for: nsError))
        } else {
            Log.app.error("Camera extension properties query failed: \(error.localizedDescription)")
        }
    }

    func request(_: OSSystemExtensionRequest,
                 foundProperties properties: [OSSystemExtensionProperties]) {
        applyProperties(properties)
    }
}
