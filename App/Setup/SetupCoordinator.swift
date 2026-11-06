import AppKit
import Foundation

/// Setup state of the virtual microphone, derived from the privileged helper's
/// registration state plus whether the audio driver is installed. Collapses the
/// old four-button helper/driver dance into a single "enable" progression.
internal enum MicrophoneStatus: Equatable {
    /// Not yet queried.
    case unknown
    /// Helper not registered, or registered+enabled but the driver isn't installed.
    case notSetUp
    /// Helper registered but the user must approve it in System Settings.
    case needsApproval
    /// Registering the helper or installing the driver is in progress.
    case installing
    /// Helper enabled and driver installed — the microphone is available.
    case ready
    /// The helper reported an install, but the installed copy is still not sealed
    /// to root: the helper serving the app is one from before an app update that
    /// has not exited. Only a restart replaces it.
    case needsReboot
    /// A setup step failed; the associated string is a user-facing reason.
    case failed(String)
}

/// App-lifetime coordinator that unifies the camera-extension install and the
/// audio helper/driver install behind one observable state and a small set of
/// guided actions. Owned by `AppDelegate`; injected into the setup window, the
/// settings UI, and the menu-bar popover so they all reflect the same truth
/// instead of each inferring it. `@MainActor`, so every property and action runs
/// on the main thread.
@MainActor @Observable
internal final class SetupCoordinator {
    private(set) var cameraStatus: CameraExtensionStatus = .unknown
    private(set) var micStatus: MicrophoneStatus = .unknown
    /// CFBundleVersion of the currently installed audio driver, or nil if none.
    private(set) var installedDriverVersion: String?
    /// Whether the installed driver is sealed to root (only meaningful with a version).
    private(set) var installedDriverSealed = true

    /// Fires on the main thread when the camera transitions into `.ready`, so the
    /// streaming model can (re)run CMIO device discovery.
    var onCameraReady: (() -> Void)?

    /// Fires on the main thread whenever `cameraStatus` actually changes, so the app
    /// can re-evaluate the proactive launch banner as async install state resolves.
    var onCameraStatusChange: (() -> Void)?

    @ObservationIgnored private let cameraController = CameraExtensionController()
    @ObservationIgnored private let audioInstaller: any AudioHelperClient
    /// Cached once; the bundled driver version is constant for an app launch.
    @ObservationIgnored private lazy var bundledDriverVersion: String? = audioInstaller.bundledDriverVersion
    @ObservationIgnored private var livenessPollTask: Task<Void, Never>?
    @ObservationIgnored private var micInstallTimeout: Task<Void, Never>?
    @ObservationIgnored private var micQueryTimeout: Task<Void, Never>?
    /// Set when the user starts mic setup, so once the helper becomes approved we
    /// install the driver automatically instead of making them click again.
    @ObservationIgnored private var autoInstallDriver = false
    /// True while a driver install is in flight, to coalesce overlapping refreshes
    /// (app reactivation + page onAppear) into a single install and to avoid a
    /// stale version query clobbering the in-progress state.
    @ObservationIgnored private var isInstallingDriver = false
    /// Names the install or removal started last. A reply or time-out carries the
    /// one it belongs to and applies only to that one: the reply to an operation
    /// that timed out can land while a newer one runs.
    @ObservationIgnored private var micOperationToken = 0
    /// Monotonic token so only the latest installed-version reply applies; drops
    /// stale async replies that would otherwise clobber freshly-changed state.
    @ObservationIgnored private var micRefreshToken = 0
    /// The token of the installed-driver check still waiting for the helper's
    /// answer, if any. Refreshes meanwhile wait for it instead of sending another,
    /// so its time limit runs out even while the setup window keeps polling.
    @ObservationIgnored private var micPendingCheck: Int?
    /// The install or removal the user last started, until a check shows how it
    /// ended: what a "Try Again" check redoes if that is still needed.
    @ObservationIgnored private var micLastOperation: MicrophoneDriverOperation?
    /// The install or removal whose failure `micStatus` shows: what "Try Again"
    /// redoes. While set, routine refreshes leave that failure up (see
    /// `MicrophoneRefresh`); the user's next microphone action clears it.
    @ObservationIgnored private var micOperationFailure: MicrophoneOperationFailure?
    /// "Try Again" is re-checking.
    @ObservationIgnored private var micRetrying = false
    /// The helper reported an install; the next check verifies the installed copy.
    @ObservationIgnored private var verifyingDriverInstall = false
    /// An install through the helper left an unsealed copy since the Mac last
    /// started, in this app session or an earlier one, so the helper is a stale one:
    /// never install through it again (no reinstall loop).
    @ObservationIgnored private lazy var staleHelperSeen = staleHelperMarker.isSet
    @ObservationIgnored private let staleHelperMarker: StaleHelperMarker

    /// Fail an in-progress driver install if the privileged helper vends a proxy
    /// but never replies (e.g. it crashes mid-request), so `micStatus` can't stick.
    @ObservationIgnored private let micOperationTimeLimit: Duration
    /// Treat a version query the helper accepted but never answered as unreachable,
    /// so a status waiting on it cannot spin forever. Counted from when the query was
    /// sent; a reply that arrives later still applies until the next query is sent.
    @ObservationIgnored private let micCheckTimeLimit: Duration

    var isMicrophoneReady: Bool { micStatus == .ready }
    /// Why the working mic should be reinstalled from this app (a newer bundled
    /// driver, or an installed copy not sealed to root), or nil.
    var microphoneUpdateReason: MicrophoneUpdateReason? {
        guard micStatus == .ready else { return nil }
        return .reason(installed: installedDriverVersion, bundled: bundledDriverVersion, sealed: installedDriverSealed)
    }
    /// The mic is installed and working, but should be updated (see the reason).
    var microphoneNeedsUpdate: Bool { microphoneUpdateReason != nil }

    /// The defaults are the app's; tests pass a fake helper, their own marker
    /// defaults, and short time limits.
    init(
        audioInstaller: any AudioHelperClient = AudioDeviceInstaller(),
        staleHelperMarker: StaleHelperMarker = StaleHelperMarker(defaults: .standard),
        micOperationTimeLimit: Duration = .seconds(30),
        micCheckTimeLimit: Duration = .seconds(10)
    ) {
        self.audioInstaller = audioInstaller
        self.staleHelperMarker = staleHelperMarker
        self.micOperationTimeLimit = micOperationTimeLimit
        self.micCheckTimeLimit = micCheckTimeLimit
        cameraController.onStatusChange = { [weak self] status in
            guard let self else { return }
            let wasReady = self.cameraStatus == .ready
            self.setCameraStatus(status)
            switch status {
            case .ready:
                self.livenessPollTask?.cancel()
                if !wasReady { self.onCameraReady?() }
            case .installing:
                self.pollCameraUntilReady()
            case .unknown, .notInstalled, .awaitingApproval, .disabled, .needsReboot,
                 .needsAppRestart, .needsRepair, .failed:
                self.livenessPollTask?.cancel()
            }
        }
    }

    /// Call once at launch. Submits the camera activation request (installs/updates
    /// or no-ops to the real state) and reads the current microphone state.
    func start() {
        cameraController.activate()
        refreshMicrophoneStatus()
    }

    /// Re-query both subsystems. Call when the app becomes active: approval happens
    /// out-of-process in System Settings with no push notification before macOS 15.1,
    /// so re-polling on reactivation is how we notice the user finished a step.
    func refreshAll() {
        cameraController.refreshStatus()
        refreshMicrophoneStatus()
    }

    // MARK: - Camera Actions

    /// Trigger (or re-trigger) camera-extension activation. Re-prompts approval if
    /// the user previously dismissed the System Settings request.
    func enableCamera() {
        cameraController.activate()
    }

    /// Repair a duplicate/zombie camera-extension install by collapsing it to a
    /// single current version (deactivate all, then reinstall). The one-click
    /// action surfaced when `cameraStatus == .needsRepair`.
    func repairCamera() {
        cameraController.repair()
    }

    /// Open System Settings to the Login Items & Extensions pane, scrolled to the
    /// Extensions list. On macOS 15+ this lands on the modern "By App" view, where
    /// LemurCam appears as a Media Extension — rather than the legacy by-category
    /// Extensions pane (com.apple.ExtensionsPreferences), which buried it under a
    /// category heading.
    func openCameraSystemSettings() {
        let settingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems"
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func pollCameraUntilReady() {
        livenessPollTask?.cancel()
        livenessPollTask = Task { [weak self] in
            let delayNs = UInt64(Tuning.setupRetryDelay * 1_000_000_000)
            for _ in 0..<Tuning.maxSetupRetries {
                try? await Task.sleep(nanoseconds: delayNs)
                guard let self, !Task.isCancelled, self.cameraStatus != .ready else { return }
                self.cameraController.refreshStatus()
            }
            // Give the final refresh time to land before deciding.
            try? await Task.sleep(nanoseconds: delayNs)
            // Enabled, but the virtual camera device never came live within the
            // budget. Hand off to the controller, which prompts a single app restart
            // and — if that already happened and the device is still absent —
            // escalates to a Mac reboot instead of looping on app restart. (macOS
            // signals the rarer reboot-on-install case via .willCompleteAfterReboot.)
            guard let self, !Task.isCancelled, self.cameraStatus == .installing else { return }
            self.cameraController.resolvePollTimeout()
        }
    }

    /// Single funnel for camera-status mutations, guarded so an unchanged status
    /// doesn't trigger redundant observation updates. Used by both the controller
    /// callback and the liveness poll's app-restart fallback.
    private func setCameraStatus(_ status: CameraExtensionStatus) {
        guard cameraStatus != status else { return }
        cameraStatus = status
        onCameraStatusChange?()
    }
}

// MARK: - Microphone Actions

extension SetupCoordinator {
    /// Advance the microphone setup by one step based on the current state:
    /// register the helper, open Login Items to approve it, or install the driver.
    func enableMicrophone() {
        micOperationFailure = nil
        switch audioInstaller.state {
        case .notRegistered, .notFound:
            autoInstallDriver = true
            registerMicHelper()
        case .requiresApproval:
            autoInstallDriver = true
            micStatus = .needsApproval
            audioInstaller.openLoginItemsSettings()
        case .enabled:
            installMicDriver()
        }
    }

    /// "Try Again" after a failure (see `MicrophoneRetry`). An install or removal the
    /// helper reported as failed is redone. After one it never answered, check the
    /// installed driver first and redo it only if that check shows it is still
    /// needed: each one restarts coreaudiod, cutting audio in every app, which a
    /// helper that was only briefly unreachable does not call for.
    func retryMicrophone() {
        let failure = micOperationFailure
        switch MicrophoneRetry.decide(
            helperEnabled: audioInstaller.state == .enabled, operationRunning: isInstallingDriver, failure: failure
        ) {
        case .continueSetup:
            enableMicrophone()
        case .ignore:
            return
        case .redo(.install):
            installMicDriver()
        case .redo(.remove):
            disableMicrophone()
        case .checkFirst:
            if let failure { micLastOperation = failure.operation }
            micOperationFailure = nil
            micRetrying = true
            micStatus = .unknown
            queryInstalledDriverVersion()
        }
    }

    /// The user moved past a failed install or removal without retrying it (Skip in
    /// guided setup): stop holding its reason, and show the microphone's state.
    func acknowledgeMicrophoneFailure() {
        guard micOperationFailure != nil else { return }
        micOperationFailure = nil
        refreshMicrophoneStatus()
    }

    /// Open the Login Items pane where the audio helper is approved.
    func openMicrophoneSystemSettings() {
        audioInstaller.openLoginItemsSettings()
    }

    private func registerMicHelper() {
        micStatus = .installing
        do {
            try audioInstaller.registerHelper()
            micStatus = .needsApproval
        } catch {
            micStatus = .failed("Couldn’t register the audio helper: \(error.localizedDescription)")
        }
    }

    private func installMicDriver() {
        // A stale helper installs unsealed copies; installing again through it
        // would only cut audio again for the same result.
        guard !staleHelperSeen else {
            micOperationFailure = nil
            micStatus = .needsReboot
            return
        }
        runMicDriverOperation(.install, audioInstaller.installDriver, failureFallback: "Driver installation failed.")
    }

    /// Reinstall the bundled driver to pick up a newer version (helper already
    /// approved, so no new System Settings prompt — just a coreaudiod restart).
    func updateMicrophone() {
        installMicDriver()
    }

    /// Remove the installed driver. The helper stays registered, so the mic can be
    /// re-enabled later without re-approving in System Settings.
    func disableMicrophone() {
        runMicDriverOperation(
            .remove, audioInstaller.uninstallDriver, failureFallback: "Couldn’t remove the microphone."
        )
    }

    /// Shared runner for install/update/remove: shows progress, coalesces
    /// overlapping operations, times out a silent helper, then re-reads state.
    private func runMicDriverOperation(
        _ kind: MicrophoneDriverOperation,
        _ operation: (@escaping (MicrophoneOperationResult) -> Void) -> Void,
        failureFallback: String
    ) {
        guard !isInstallingDriver else { return }
        isInstallingDriver = true
        micOperationToken += 1
        let token = micOperationToken
        micLastOperation = kind
        micOperationFailure = nil
        micStatus = .installing
        dropPendingDriverCheck()
        micInstallTimeout?.cancel()
        let timeLimit = micOperationTimeLimit
        micInstallTimeout = Task { [weak self] in
            try? await Task.sleep(for: timeLimit)
            guard let self, !Task.isCancelled, self.micOperationToken == token, self.isInstallingDriver else { return }
            self.isInstallingDriver = false
            self.failMicOperation(
                kind, reportedByHelper: false, message: "The microphone helper didn’t respond. Please try again.",
                fallback: failureFallback
            )
        }
        operation { [weak self] result in
            Task { @MainActor in
                // A reply to an earlier operation, which timed out, must not end
                // this one or stop its time limit.
                guard let self, self.micOperationToken == token else { return }
                self.micInstallTimeout?.cancel()
                self.isInstallingDriver = false
                switch result {
                case .succeeded:
                    // Also replaces a "didn't respond" failure this reply came too late for.
                    self.micOperationFailure = nil
                    if kind == .install { self.verifyingDriverInstall = true }
                    self.refreshMicrophoneStatus()
                case .failed(let message):
                    self.failMicOperation(kind, reportedByHelper: true, message: message, fallback: failureFallback)
                case .noAnswer(let message):
                    self.failMicOperation(kind, reportedByHelper: false, message: message, fallback: failureFallback)
                }
            }
        }
    }

    /// Show why the operation failed (`fallback` when the reason is empty), and keep
    /// what "Try Again" redoes.
    private func failMicOperation(
        _ kind: MicrophoneDriverOperation, reportedByHelper: Bool, message: String, fallback: String
    ) {
        micOperationFailure = MicrophoneOperationFailure(operation: kind, reportedByHelper: reportedByHelper)
        micStatus = .failed(message.isEmpty ? fallback : message)
    }

    /// Re-read the microphone's state: the microphone half of `refreshAll`.
    func refreshMicrophoneStatus() {
        // The helper's registration state is synchronous and authoritative for the
        // not-installed cases; only query the driver version (async XPC) when the
        // helper is approved, so a transient XPC failure can't masquerade as state.
        switch MicrophoneRefresh.decide(
            helper: audioInstaller.state, operationRunning: isInstallingDriver,
            holdingFailure: micOperationFailure != nil
        ) {
        case .checkDriver:
            queryInstalledDriverVersion()
        case .setStatus(let status):
            if status == .notSetUp { installedDriverVersion = nil }
            micStatus = status
        case .keepStatus:
            return
        }
    }

    private func queryInstalledDriverVersion() {
        // The check already on its way answers for this refresh too (its reply is
        // applied against the state at that time). Sending another would push its
        // time limit back, and with the setup window polling every 2.5 s, a helper
        // that accepts a check but never answers would leave a spinner up for good.
        guard micPendingCheck == nil else { return }
        micRefreshToken += 1
        let token = micRefreshToken
        micPendingCheck = token
        micQueryTimeout?.cancel()
        let timeLimit = micCheckTimeLimit
        micQueryTimeout = Task { [weak self] in
            try? await Task.sleep(for: timeLimit)
            guard let self, !Task.isCancelled, self.micPendingCheck == token else { return }
            self.micPendingCheck = nil
            self.applyDriverCheck(.unreachable, token: token)
        }
        audioInstaller.installedDriver { [weak self] check in
            Task { @MainActor in
                guard let self else { return }
                if self.micPendingCheck == token {
                    self.micPendingCheck = nil
                    self.micQueryTimeout?.cancel()
                }
                self.applyDriverCheck(check, token: token)
            }
        }
    }

    /// Stop waiting for the check on its way, if any: an install or removal is
    /// starting, and a check sent before it must not answer for the state after it.
    private func dropPendingDriverCheck() {
        micRefreshToken += 1
        micPendingCheck = nil
        micQueryTimeout?.cancel()
    }

    private func applyDriverCheck(_ check: InstalledDriverCheck, token: Int) {
        // Apply only the latest query, and never during an install.
        guard token == micRefreshToken, !isInstallingDriver else { return }
        let reply = MicrophoneVersionReply.decide(check, context: MicrophoneCheckContext(
            currentStatus: micStatus,
            autoInstallPending: autoInstallDriver,
            retrying: micRetrying,
            lastOperation: micLastOperation,
            verifyingInstall: verifyingDriverInstall,
            staleHelperSeen: staleHelperSeen,
            bundledVersion: bundledDriverVersion,
            holdingFailure: micOperationFailure != nil
        ))
        micRetrying = false
        if check.reachable {
            installedDriverVersion = check.version
            installedDriverSealed = check.sealed
            if check.version != nil { autoInstallDriver = false }
            // The check shows how the last operation ended.
            verifyingDriverInstall = false
            micLastOperation = nil
        }
        switch reply {
        case .keepStatus:
            return
        case .installDriver:
            autoInstallDriver = false
            installMicDriver()
        case .uninstallDriver:
            disableMicrophone()
        case .setStatus(let status):
            if status == .needsReboot {
                staleHelperSeen = true
                staleHelperMarker.record()
            }
            micStatus = status
        }
    }
}
