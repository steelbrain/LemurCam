import SwiftUI

/// A request the setup wizard hands back to its owner (`AppDelegate`). Keeping
/// these as one callback lets the host own all side effects — restarting,
/// persisting step completion, dismissing — while the view stays declarative.
internal enum SetupAction {
    /// Step 1's "Restart LemurCam" — relaunch to bring the camera device live.
    case restart
    /// The user explicitly advanced past (or finished) the given step, so its
    /// per-step completion flag should be persisted.
    case completedStep(SetupStep)
    /// Dismiss the wizard. `openCameras == true` also routes to Settings → Cameras.
    case dismiss(openCameras: Bool)
}

/// Guided, three-step setup wizard. Walks the user through the camera system
/// extension (step 1, required), the optional microphone audio driver (step 2),
/// and optionally adding an IP camera (step 3) — one step at a time, with live
/// status driven by the shared `SetupCoordinator`. macOS surfaces approval
/// out-of-process, so the steps update as the window polls the coordinator and as
/// `AppDelegate` re-polls on reactivation.
///
/// The wizard only *renders* status; it never re-derives install/restart state.
/// Step gating (`cameraStepDone`) reads `coordinator.cameraStatus` as-is.
internal struct SetupView: View {
    private let coordinator: SetupCoordinator
    private let sourceManager: SourceManager?
    /// Side effects the host performs on the wizard's behalf (see `SetupAction`).
    private let onAction: ((SetupAction) -> Void)?

    @State private var step: SetupStep
    /// Direction of the last navigation, so step transitions slide the right way.
    @State private var navigatingBack = false

    internal init(
        coordinator: SetupCoordinator,
        sourceManager: SourceManager? = nil,
        initialStep: SetupStep = .camera,
        onAction: ((SetupAction) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.sourceManager = sourceManager
        self.onAction = onAction
        _step = State(initialValue: initialStep)
    }

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Centered, non-scrolling: the window is sized to the tallest step so
            // content always fits without a scroll bar.
            ZStack {
                stepContent
                    .padding(.horizontal, 28)
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: step)
            Divider()
            footer
        }
        .frame(width: Tuning.setupWindowWidth, height: Tuning.setupWindowHeight)
        // Approval happens out-of-process in System Settings; poll while the
        // window is open so each step flips to its next state promptly without
        // the user having to click back into the app first.
        .task { await pollWhileOpen() }
    }

    private func pollWhileOpen() async {
        while !Task.isCancelled {
            coordinator.refreshAll()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
    }

    /// Slide + fade between steps, directional so Back feels like going back.
    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: navigatingBack ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: navigatingBack ? .trailing : .leading).combined(with: .opacity)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 60, height: 60)
            }
            Text("Set Up LemurCam")
                .font(.title2.bold())
            stepIndicator
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var stepIndicator: some View {
        VStack(spacing: 8) {
            Text("Step \(step.displayNumber) of \(SetupStep.total)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(SetupStep.allCases) { dot in
                    Capsule()
                        .fill(dot.rawValue <= step.rawValue ? Color.accentColor : Color.gray.opacity(0.25))
                        .frame(width: dot == step ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: step)
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .camera:
            stepBody(
                symbol: "video.fill", title: "Virtual Camera",
                detail: cameraDetail(coordinator.cameraStatus), state: cameraStepState
            ) { cameraControl(coordinator.cameraStatus) }
        case .microphone:
            stepBody(
                symbol: "mic.fill", title: "Virtual Microphone",
                detail: micDetail(coordinator.micStatus), state: micStepState
            ) { micControl(coordinator.micStatus) }
        case .addCamera:
            stepBody(
                symbol: "video.badge.plus", title: "Your Camera",
                detail: addCameraDetail, state: addCameraState
            ) { addCameraControl }
        }
    }

    private func stepBody<Control: View>(
        symbol: String, title: String, detail: String, state: SetupStepState,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(spacing: 24) {
            SetupDeviceHero(symbol: symbol, title: title, detail: detail, state: state)
            control()
                .controlSize(.large)
        }
    }

    // MARK: - Footer / Navigation

    private var footer: some View {
        HStack {
            leadingButton
            Spacer()
            primaryButton
        }
        .padding(16)
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch SetupFooterButtons.leading(for: step, cameraStepDone: cameraStepDone) {
        case .back:
            Button("Back") { goBack() }
        case .setUpLater:
            Button("Set Up Later") { onAction?(.dismiss(openCameras: false)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch SetupFooterButtons.primary(
            for: step, cameraStepDone: cameraStepDone, micReady: coordinator.isMicrophoneReady
        ) {
        case .continueStep:
            Button("Continue") { advance() }
                .keyboardShortcut(.defaultAction)
        case .skip:
            Button("Skip for Now") { advance() }
                .keyboardShortcut(.defaultAction)
        case .done:
            Button("Done") {
                onAction?(.completedStep(.addCamera))
                onAction?(.dismiss(openCameras: false))
            }
            .keyboardShortcut(.defaultAction)
        case nil:
            EmptyView()
        }
    }

    private func advance() {
        onAction?(.completedStep(step))
        guard let next = step.next else { return }
        navigatingBack = false
        step = next
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        navigatingBack = true
        step = previous
    }

    /// Whether the camera step may be advanced past. Only once the camera is
    /// actually live (`.ready`) — a pending app restart or Mac reboot must be taken
    /// first, so "Continue" never sits next to a still-required "Restart" action.
    private var cameraStepDone: Bool {
        SetupCameraGate.canAdvance(coordinator.cameraStatus)
    }
}

// MARK: - Status → hero state

private extension SetupView {
    var cameraStepState: SetupStepState {
        switch coordinator.cameraStatus {
        case .ready: return .ready
        case .installing, .unknown: return .working
        case .awaitingApproval, .disabled, .needsReboot, .needsAppRestart, .needsRepair, .notInstalled:
            return .actionNeeded
        case .failed: return .failed
        }
    }

    var micStepState: SetupStepState {
        switch coordinator.micStatus {
        case .ready: return .ready
        case .installing, .unknown: return .working
        case .needsApproval, .notSetUp: return .actionNeeded
        case .failed: return .failed
        }
    }

    var addCameraState: SetupStepState {
        (sourceManager?.sources.count ?? 0) > 0 ? .ready : .inactive
    }
}

// MARK: - Camera content

private extension SetupView {
    func cameraDetail(_ status: CameraExtensionStatus) -> String {
        switch status {
        case .ready: return "Ready — other apps can now select “LemurCam”."
        case .awaitingApproval:
            return "Allow LemurCam in System Settings → General → Login Items & Extensions, then come back here."
        case .disabled:
            return "The camera is turned off. Re-enable LemurCam in "
                + "System Settings → General → Login Items & Extensions."
        case .needsReboot, .needsAppRestart, .needsRepair:
            return cameraRecoveryDetail(status)
        case .installing: return "Installing… this can take a few seconds."
        case .failed(let message): return message
        case .unknown, .notInstalled:
            return "Required. Enable the camera to start streaming your IP camera."
        }
    }

    /// Detail copy for the post-install recovery states, split out of `cameraDetail`
    /// to keep that switch under the cyclomatic-complexity limit.
    func cameraRecoveryDetail(_ status: CameraExtensionStatus) -> String {
        switch status {
        case .needsReboot: return "Restart your Mac to finish updating the camera."
        case .needsAppRestart:
            return "Almost there — restart LemurCam to finish. Only the app restarts, not your Mac."
        case .needsRepair:
            return "Multiple camera extensions are installed. Repair resets it to one working version."
        default: return ""
        }
    }

    @ViewBuilder
    func cameraControl(_ status: CameraExtensionStatus) -> some View {
        switch status {
        case .ready, .installing, .unknown, .needsReboot:
            // The hero's status indicator conveys these; no action to take here.
            EmptyView()
        case .awaitingApproval, .disabled:
            Button("Open System Settings") { coordinator.openCameraSystemSettings() }
                .buttonStyle(.borderedProminent)
        case .needsAppRestart:
            Button("Restart LemurCam") { onAction?(.restart) }
                .buttonStyle(.borderedProminent)
        case .needsRepair:
            Button("Repair") { coordinator.repairCamera() }
                .buttonStyle(.borderedProminent)
        case .notInstalled:
            Button("Enable Camera") { coordinator.enableCamera() }
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Try Again") { coordinator.enableCamera() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Microphone content

private extension SetupView {
    func micDetail(_ status: MicrophoneStatus) -> String {
        switch status {
        case .ready: return "Ready — “LemurCam Microphone” is available to other apps."
        case .needsApproval:
            return "Approve LemurCam in System Settings → General → Login Items & Extensions, then come back."
        case .installing: return "Setting up… this can take a few seconds."
        case .failed(let message): return message
        case .unknown, .notSetUp:
            return "Optional. Adds a microphone fed by your camera’s audio. You can skip this."
        }
    }

    @ViewBuilder
    func micControl(_ status: MicrophoneStatus) -> some View {
        switch status {
        case .ready, .installing, .unknown:
            EmptyView()
        case .needsApproval:
            Button("Open System Settings") { coordinator.openMicrophoneSystemSettings() }
                .buttonStyle(.borderedProminent)
        case .notSetUp:
            Button("Enable Microphone") { coordinator.enableMicrophone() }
                .buttonStyle(.borderedProminent)
        case .failed:
            Button("Try Again") { coordinator.enableMicrophone() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Add-camera content

private extension SetupView {
    var addCameraDetail: String {
        let count = sourceManager?.sources.count ?? 0
        return count == 0
            ? "Add an IP camera (RTSP or ONVIF) so LemurCam has a feed to stream."
            : "\(count) camera\(count == 1 ? "" : "s") added."
    }

    @ViewBuilder
    var addCameraControl: some View {
        if (sourceManager?.sources.count ?? 0) == 0 {
            Button("Add Camera") {
                onAction?(.completedStep(.addCamera))
                onAction?(.dismiss(openCameras: true))
            }
            .buttonStyle(.borderedProminent)
        } else {
            EmptyView()
        }
    }
}
