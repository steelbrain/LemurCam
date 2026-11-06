import AppKit
import SwiftUI

@MainActor
internal final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running app delegate. `@NSApplicationDelegateAdaptor` makes SwiftUI's own
    /// object `NSApp.delegate` and forwards to this instance, so `NSApp.delegate as?
    /// AppDelegate` is always nil. Code outside the SwiftUI scene (App Intents,
    /// `NSApp.relaunch()`) reaches the delegate through this instead.
    private(set) static weak var shared: AppDelegate?

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
    /// The Settings window's selected pane; survives the window so a reopened
    /// Settings can be routed to a pane before it appears.
    private let settingsNavigation = SettingsNavigation()
    /// Whether the menu bar popover is showing (between will-show and did-close).
    private var isPopoverOpen = false
    var helpWindow: NSWindow?
    var aboutWindow: NSWindow?
    /// Set when the user puts the launch banner away ("Later", its close button,
    /// Cmd-W), so it doesn't reappear on every reactivation this session; it returns
    /// at the next launch if the upgrade-pending state persists.
    private var launchNudgeDismissed = false
    private var globalClickMonitor: Any?
    /// True once `applicationDidFinishLaunching` got past the launch guards and set
    /// the app up. A guard that quits before then must not hit the quit prompt.
    private(set) var hasFinishedLaunching = false
    /// Set by `relaunch()` so the restart quits without the "Camera in Use" prompt.
    var isRelaunching = false

    /// Owns guided-setup completion, scoped to the running app version. A version
    /// change clears the per-step flags so each new version re-runs setup. See
    /// `SetupStateStore` for the persistence and `SetupLaunchDecision` for the
    /// pure decisions; both are unit tested.
    private let setupStateStore = SetupStateStore(
        defaults: .standard,
        version: AppDelegate.appVersionIdentity
    )

    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self

        // When the app is only the unit-test host, do no real launch work (`TestHost`).
        if TestHost.isThisProcess { return }

        if terminateIfAlreadyRunning() { return }
        if terminateIfNotInApplications() { return }
        RuntimeFlags.captureLaunchedFormat()

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
        settingsNavigation.onSelectionChange = { [weak self] in self?.updatePreviewDemand() }

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
        hasFinishedLaunching = true
        // A status change during launch was held back until now; evaluate it.
        presentLaunchNudgeIfNeeded()
    }

    func applicationDidBecomeActive(_: Notification) {
        // xcodebuild can activate the test host: no camera query or helper XPC there.
        if TestHost.isThisProcess { return }
        // Approval happens out-of-process in System Settings, where Login Items can
        // change too; re-poll on reactivation to notice when the user finishes a step.
        setupCoordinator.refreshAll()
        launchAtLoginManager.refresh()
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
        launchAtLoginManager.refresh()
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
        // Consumer state comes from this process's Darwin-notification tracking. The
        // extension runs as a different user, so app-group defaults can't carry it.
        let decision = TerminationDecision.evaluate(
            hasFinishedLaunching: hasFinishedLaunching,
            isRelaunching: isRelaunching,
            hasExternalConsumers: streamCoordinator?.hasExternalConsumers ?? false
        )
        guard decision == .confirmCameraInUse else { return .terminateNow }

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
        presentSettings()
    }

    /// Bring up Settings. `tab` switches to that pane even if Settings is already
    /// open; nil keeps an open window's pane and starts a new one on Setup & Status.
    func presentSettings(showing tab: SettingsTab? = nil) {
        if let window = settingsWindow {
            if let tab { settingsNavigation.selection = tab }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            retireLaunchNudge()
            return
        }

        settingsNavigation.selection = tab ?? .status
        let view = SettingsView(
            sourceManager: sourceManager,
            launchAtLoginManager: launchAtLoginManager,
            previewStore: streamCoordinator?.previewStore,
            setup: setupCoordinator,
            openSetup: { [weak self] in self?.openSetupWindow() },
            navigation: settingsNavigation
        )
        // The sidebar `NavigationSplitView` needs a full-size content view. Without
        // it, macOS 27 draws the toolbar's scroll-edge glass over the top of each
        // pane and parks the sidebar toggle mid-toolbar instead of on the sidebar.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Tuning.settingsWindowWidth, height: Tuning.settingsWindowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: view)
        window.setFrameAutosaveName("LemurCamSettings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window
        updatePreviewDemand()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        retireLaunchNudge()
    }

    /// Selector-compatible entry point (menu item, popover, settings). Opens the
    /// wizard at the first step.
    @objc func openSetupWindow() {
        openSetupWindow(at: .camera)
    }

    func openSetupWindow(at step: SetupStep) {
        if let window = setupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            retireLaunchNudge()
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
        retireLaunchNudge()
    }

    /// The launch banner is a backstop for users who never open a window; once
    /// Settings or the wizard is up (both show the same restart prompt), retire it.
    /// Call only after the new window is front: closing the banner while it is the
    /// only window makes `windowWillClose` drop the app to `.accessory`, which can
    /// leave the window being presented hidden.
    private func retireLaunchNudge() {
        nudgeWindow?.close()
    }

    /// Keep the stream connected for the in-app preview only while something shows
    /// it: the popover, or Settings on its Preview pane.
    private func updatePreviewDemand() {
        streamCoordinator?.previewStore.isPreviewEnabled = PreviewDemandDecision.isPreviewNeeded(
            popoverOpen: isPopoverOpen,
            settingsPane: settingsWindow == nil ? nil : settingsNavigation.selection
        )
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
        // Don't compete with guided setup or Settings while either is open (both
        // show the same restart prompt), nor flash ahead of the wizard during launch.
        // A pending step the user put off with "Set Up Later" doesn't block it. See
        // `LaunchNudgeGate`.
        guard LaunchNudgeGate.canPresent(
            hasFinishedLaunching: hasFinishedLaunching,
            setupWindowOpen: setupWindow != nil,
            settingsWindowOpen: settingsWindow != nil
        ) else {
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
            if openCameras { presentSettings(showing: .cameras) }
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
    func popoverWillShow(_: Notification) {
        isPopoverOpen = true
        updatePreviewDemand()
    }

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
        isPopoverOpen = false
        updatePreviewDemand()
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    /// Asked only when the user closes a window (its close button, Cmd-W, or a
    /// `performClose` such as the banner's "Later"); the app's own `close()` calls
    /// (`retireLaunchNudge`, the banner's state clearing) skip it. A user closing the
    /// launch banner has put it off, as "Later" does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === nudgeWindow { launchNudgeDismissed = true }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            updatePreviewDemand()
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
