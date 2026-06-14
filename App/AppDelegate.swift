import AppKit
import AVFoundation
import SwiftUI

@MainActor
internal final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var streamCoordinator: StreamCoordinator?
    private let launchAtLoginManager = LaunchAtLoginManager()
    let sourceManager = SourceManager()
    let setupCoordinator = SetupCoordinator()
    private var bootChecker: BootSanityChecker?
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var nudgeWindow: NSWindow?
    var helpWindow: NSWindow?
    var aboutWindow: NSWindow?
    /// Set when the user clicks "Later" on the launch banner, so it doesn't reappear
    /// on every reactivation this session; it returns at the next launch if the
    /// upgrade-pending state persists.
    private var launchNudgeDismissed = false
    private var globalClickMonitor: Any?

    /// Owns guided-setup completion, scoped to the running app version. A version
    /// change clears the per-step flags so each new version re-runs setup. See
    /// `SetupStateStore` for the persistence and `SetupLaunchDecision` for the
    /// pure decisions; both are unit tested.
    private let setupStateStore = SetupStateStore(
        defaults: .standard,
        version: AppDelegate.appVersionIdentity
    )

    func applicationDidFinishLaunching(_: Notification) {
        // When the app is only the unit-test host, do no real launch work: system-
        // extension activation, streaming, and the status item can block on OS
        // approval dialogs / IPC and hang the headless test run. The pure logic under
        // test never needs AppDelegate to launch. `XCTestConfigurationFilePath` is set
        // in the host's environment before the process starts, so it's reliable here
        // even before the test bundle (and `XCTestCase`) finishes loading.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return
        }

        if terminateIfAlreadyRunning() { return }
        if terminateIfNotInApplications() { return }

        DualLogger.onEmit = { category, level, message in
            Task { @MainActor in
                LogStore.shared.append(category: category, level: level, message: message)
            }
        }

        sourceManager.load()

        let coordinator = StreamCoordinator(sourceManager: sourceManager)
        coordinator.start()
        streamCoordinator = coordinator

        setupStatusItem()
        setupPopover()

        // The coordinator installs/activates the extension and reports real state;
        // discovery runs once the virtual camera device is live.
        setupCoordinator.onCameraReady = { [weak coordinator] in
            coordinator?.beginCameraDiscovery()
        }
        // Re-evaluate the proactive launch banner as the async install state
        // resolves (e.g. an in-place upgrade settling into .needsAppRestart).
        setupCoordinator.onCameraStatusChange = { [weak self] in
            self?.presentLaunchNudgeIfNeeded()
        }
        setupCoordinator.start()

        let checker = BootSanityChecker(sourceManager: sourceManager)
        checker.run()
        bootChecker = checker

        // First run (or first run of a new app version): guide the user through
        // setup, resuming on the first step they have not yet completed. A restart
        // during step 1 (e.g. approving the camera extension) reopens here on step
        // 1 — now showing the live camera — rather than skipping ahead.
        setupStateStore.resetForVersionChangeIfNeeded()
        if let step = setupStateStore.launchStep() {
            openSetupWindow(at: step)
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        // Approval happens out-of-process in System Settings; re-poll on
        // reactivation to notice when the user finishes a step.
        setupCoordinator.refreshAll()
        presentLaunchNudgeIfNeeded()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "web.camera", accessibilityDescription: "LemurCam")
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.delegate = self
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from sender: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            streamCoordinator?.previewStore.isPreviewEnabled = true
            let view = PopoverView(
                setup: setupCoordinator,
                sourceManager: sourceManager,
                previewStore: streamCoordinator?.previewStore,
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    DispatchQueue.main.async {
                        self?.openSettings()
                    }
                },
                openSetup: { [weak self] in
                    self?.popover.performClose(nil)
                    DispatchQueue.main.async {
                        self?.openSetupWindow()
                    }
                }
            )
            popover.contentViewController = NSHostingController(rootView: view)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    private func showContextMenu(from _: NSView) {
        let menu = NSMenu()

        let launchItem = menuItem("Launch at Login", #selector(toggleLaunchAtLogin))
        launchItem.state = launchAtLoginManager.isEnabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(menuItem("Set Up LemurCam\u{2026}", #selector(openSetupWindow as () -> Void)))
        menu.addItem(menuItem("Settings\u{2026}", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("LemurCam Help", #selector(openHelpWindow)))
        menu.addItem(menuItem("About LemurCam", #selector(showAboutPanel)))
        menu.addItem(menuItem("Quit LemurCam", #selector(quitApp), key: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLoginManager.setEnabled(!launchAtLoginManager.isEnabled)
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let hasConsumers = LemurCamConfig.sharedDefaults?.bool(
            forKey: LemurCamConfig.hasExternalConsumersKey
        ) ?? false

        guard hasConsumers else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Camera in Use"
        alert.informativeText = "Another app is using the LemurCam virtual camera. Quitting will stop the video feed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

}

// MARK: - Windows & Panels

extension AppDelegate {
    @objc func openSettings() {
        presentSettings(initialTab: .status)
    }

    func presentSettings(initialTab: SettingsTab) {
        // The launch banner is a backstop for users who never open a window; once
        // Settings is up (it shows the same restart prompt), retire it.
        nudgeWindow?.close()
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        streamCoordinator?.previewStore.isPreviewEnabled = true
        let view = SettingsView(
            sourceManager: sourceManager,
            launchAtLoginManager: launchAtLoginManager,
            previewStore: streamCoordinator?.previewStore,
            setup: setupCoordinator,
            openSetup: { [weak self] in self?.openSetupWindow() },
            initialTab: initialTab
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Tuning.settingsWindowWidth, height: Tuning.settingsWindowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: view)
        window.setFrameAutosaveName("LemurCamSettings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Selector-compatible entry point (menu item, popover, settings). Opens the
    /// wizard at the first step.
    @objc func openSetupWindow() {
        openSetupWindow(at: .camera)
    }

    func openSetupWindow(at step: SetupStep) {
        // The launch banner is a backstop for users who never open a window; once the
        // wizard is up (it shows the same restart prompt), retire it.
        nudgeWindow?.close()
        if let window = setupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SetupView(
            coordinator: setupCoordinator,
            sourceManager: sourceManager,
            initialStep: step,
            onAction: { [weak self] action in self?.handleSetupAction(action) }
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: Tuning.setupWindowWidth, height: Tuning.setupWindowHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up LemurCam"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Present (or tear down) the proactive launch banner based on the current
    /// camera state. The banner is for users who never open a window after an
    /// in-place upgrade, so it stays out of the way when guided setup or Settings is
    /// already showing the same restart prompt, and once dismissed it doesn't nag on
    /// every reactivation — it returns at the next launch if the state persists.
    private func presentLaunchNudgeIfNeeded() {
        guard let nudge = LaunchNudgeDecision.evaluate(cameraStatus: setupCoordinator.cameraStatus) else {
            // State cleared (e.g. the restart took): retire a stale banner.
            nudgeWindow?.close()
            return
        }
        // Guided setup owns the upgrade flow: it auto-opens whenever any step is
        // unfinished (including after a version change) and shows the same restart
        // prompt. The banner is only a backstop for when setup is already complete,
        // so don't compete with a pending or open wizard (nor the Settings window).
        //
        // The `launchStep() == nil` check is also load-bearing for launch ordering:
        // `setupCoordinator.start()` can drive a status change (firing this) before
        // `applicationDidFinishLaunching` opens the setup window, so at that instant
        // `setupWindow` is still nil. Suppressing on a pending step keeps the banner
        // from flashing ahead of the wizard. Don't weaken this to a window-only gate.
        guard setupStateStore.launchStep() == nil, setupWindow == nil, settingsWindow == nil else {
            return
        }
        if let hosting = nudgeWindow?.contentView as? NSHostingView<LaunchNudgeView> {
            // Already showing: refresh content so an escalation (app restart →
            // reboot) can't leave a stale, wrong-action banner up. The hosting view
            // resizes the window via .preferredContentSize; re-center to match.
            hosting.rootView = makeLaunchNudgeView(nudge)
            nudgeWindow?.center()
            return
        }
        guard !launchNudgeDismissed else { return }
        showLaunchNudge(nudge)
    }

    private func makeLaunchNudgeView(_ nudge: LaunchNudge) -> LaunchNudgeView {
        LaunchNudgeView(
            nudge: nudge,
            onRestart: { NSApp.relaunch() },
            onDismiss: { [weak self] in
                self?.launchNudgeDismissed = true
                self?.nudgeWindow?.performClose(nil)
            }
        )
    }

    private func showLaunchNudge(_ nudge: LaunchNudge) {
        let hosting = NSHostingView(rootView: makeLaunchNudgeView(nudge))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Tuning.launchNudgeWindowWidth, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "LemurCam"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        nudgeWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Perform a wizard-requested side effect on its behalf (see `SetupAction`).
    private func handleSetupAction(_ action: SetupAction) {
        switch action {
        case .restart:
            // Only the app restarts (not the Mac); the relaunch brings the camera
            // device live. The user lands back on step 1 — still not marked done —
            // now showing the live camera, and advances from there.
            NSApp.relaunch()
        case .completedStep(let step):
            setupStateStore.markComplete(step)
        case .dismiss(let openCameras):
            // Present Settings → Cameras *before* closing the wizard. performClose
            // runs windowWillClose synchronously, which — with no other window open
            // — drops the app to .accessory; presenting afterwards then raced that
            // policy flip and left the Settings window hidden (the "Add Camera"
            // dead-end). Opening first keeps a window alive across the handoff, so
            // the activation policy never flips and Settings reliably comes forward.
            if openCameras { presentSettings(initialTab: .cameras) }
            setupWindow?.performClose(nil)
        }
    }

    /// Identifies the running app by marketing version and build number. Guided
    /// setup completion is scoped to this string; any change resets it.
    private static var appVersionIdentity: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_: Notification) {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    func popoverDidClose(_: Notification) {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        // Disable preview when popover closes (unless settings window is open)
        if settingsWindow == nil {
            streamCoordinator?.previewStore.isPreviewEnabled = false
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            // Only disable preview if popover is also closed
            if !popover.isShown {
                streamCoordinator?.previewStore.isPreviewEnabled = false
            }
        } else if window === setupWindow {
            setupWindow = nil
        } else if window === nudgeWindow {
            nudgeWindow = nil
        } else if window === helpWindow {
            helpWindow = nil
        } else if window === aboutWindow {
            aboutWindow = nil
        } else {
            return
        }
        // Drop back to menu-bar-only once no app window remains open.
        if settingsWindow == nil, setupWindow == nil, nudgeWindow == nil,
           helpWindow == nil, aboutWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
