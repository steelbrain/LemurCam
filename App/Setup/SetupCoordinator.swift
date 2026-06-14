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

    /// Fires on the main thread when the camera transitions into `.ready`, so the
    /// streaming model can (re)run CMIO device discovery.
    var onCameraReady: (() -> Void)?

    /// Fires on the main thread whenever `cameraStatus` actually changes, so the app
    /// can re-evaluate the proactive launch banner as async install state resolves.
    var onCameraStatusChange: (() -> Void)?

    @ObservationIgnored private let cameraController = CameraExtensionController()
    @ObservationIgnored private let audioInstaller = AudioDeviceInstaller()
    /// Cached once; the bundled driver version is constant for an app launch.
    @ObservationIgnored private lazy var bundledDriverVersion: String? = audioInstaller.bundledDriverVersion
    @ObservationIgnored private var livenessPollTask: Task<Void, Never>?
    @ObservationIgnored private var micInstallTimeout: Task<Void, Never>?
    /// Set when the user starts mic setup, so once the helper becomes approved we
    /// install the driver automatically instead of making them click again.
    @ObservationIgnored private var autoInstallDriver = false
    /// True while a driver install is in flight, to coalesce overlapping refreshes
    /// (app reactivation + page onAppear) into a single install and to avoid a
    /// stale version query clobbering the in-progress state.
    @ObservationIgnored private var isInstallingDriver = false
    /// Monotonic token so only the latest installed-version reply applies; drops
    /// stale async replies that would otherwise clobber freshly-changed state.
    @ObservationIgnored private var micRefreshToken = 0

    /// Fail an in-progress driver install if the privileged helper vends a proxy
    /// but never replies (e.g. it crashes mid-request), so `micStatus` can't stick.
    private static let micInstallTimeoutNs: UInt64 = 30_000_000_000

    /// The camera is the core feature and is required; the microphone is optional.
    var isCameraReady: Bool { cameraStatus == .ready }
    var isMicrophoneReady: Bool { micStatus == .ready }
    /// The mic is installed and working, but this app build ships a newer driver.
    var microphoneNeedsUpdate: Bool {
        guard micStatus == .ready, let installed = installedDriverVersion,
              let bundled = bundledDriverVersion else { return false }
        return ExtensionUpgradeDecision.isUpdateAvailable(installed: installed, bundled: bundled)
    }
    /// Whether the guided setup flow should be surfaced (camera not yet running).
    var needsSetup: Bool { cameraStatus != .ready }

    init() {
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

    // MARK: - Microphone Actions

    /// Advance the microphone setup by one step based on the current state:
    /// register the helper, open Login Items to approve it, or install the driver.
    func enableMicrophone() {
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
        runMicDriverOperation(audioInstaller.installDriver, failureFallback: "Driver installation failed.")
    }

    /// Reinstall the bundled driver to pick up a newer version (helper already
    /// approved, so no new System Settings prompt — just a coreaudiod restart).
    func updateMicrophone() {
        installMicDriver()
    }

    /// Remove the installed driver. The helper stays registered, so the mic can be
    /// re-enabled later without re-approving in System Settings.
    func disableMicrophone() {
        runMicDriverOperation(audioInstaller.uninstallDriver, failureFallback: "Couldn’t remove the microphone.")
    }

    /// Shared runner for install/update/remove: shows progress, coalesces
    /// overlapping operations, times out a silent helper, then re-reads state.
    private func runMicDriverOperation(
        _ operation: (@escaping (Bool, String) -> Void) -> Void,
        failureFallback: String
    ) {
        guard !isInstallingDriver else { return }
        isInstallingDriver = true
        micStatus = .installing
        micInstallTimeout?.cancel()
        micInstallTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.micInstallTimeoutNs)
            guard let self, !Task.isCancelled, self.isInstallingDriver else { return }
            self.isInstallingDriver = false
            self.micStatus = .failed("The microphone helper didn’t respond. Please try again.")
        }
        operation { [weak self] success, message in
            Task { @MainActor in
                guard let self else { return }
                self.micInstallTimeout?.cancel()
                self.isInstallingDriver = false
                if success {
                    self.refreshMicrophoneStatus()
                } else {
                    self.micStatus = .failed(message.isEmpty ? failureFallback : message)
                }
            }
        }
    }

    private func refreshMicrophoneStatus() {
        // The helper's registration state is synchronous and authoritative for the
        // not-installed cases; only query the driver version (async XPC) when the
        // helper is approved, so a transient XPC failure can't masquerade as state.
        switch audioInstaller.state {
        case .notRegistered, .notFound:
            guard !isInstallingDriver else { return }
            installedDriverVersion = nil
            micStatus = .notSetUp
        case .requiresApproval:
            guard !isInstallingDriver else { return }
            micStatus = .needsApproval
        case .enabled:
            queryInstalledDriverVersion()
        }
    }

    private func queryInstalledDriverVersion() {
        micRefreshToken += 1
        let token = micRefreshToken
        audioInstaller.installedVersion { [weak self] reachable, version in
            Task { @MainActor in
                // Apply only the latest query, never during an install, and never
                // when the helper was unreachable (a hiccup, not "not installed").
                guard let self, token == self.micRefreshToken, !self.isInstallingDriver else { return }
                guard reachable else { return }
                self.installedDriverVersion = version
                // Helper just got approved mid-setup with no driver yet: finish now.
                if version == nil, self.autoInstallDriver {
                    self.autoInstallDriver = false
                    self.installMicDriver()
                    return
                }
                if version != nil { self.autoInstallDriver = false }
                self.micStatus = version == nil ? .notSetUp : .ready
            }
        }
    }
}
