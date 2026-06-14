import SwiftUI

/// Settings hub for LemurCam's two virtual devices — the camera system extension
/// and the optional microphone. Shows each one's live status and the single
/// contextual action to advance or recover it, plus mic management (update /
/// remove). The dedicated guided window (Open Guided Setup) remains the first-run
/// path; this page is the ongoing manage-everything-in-one-place surface.
internal struct StatusSettingsView: View {
    var setup: SetupCoordinator
    var openSetup: (() -> Void)?

    @State private var showRemoveMic = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatusCard(
                    symbol: "video.fill",
                    title: "Virtual Camera",
                    subtitle: cameraSubtitle,
                    state: cameraCardState,
                    statusText: cameraStatusText,
                    action: cameraAction
                )
                StatusCard(
                    symbol: "mic.fill",
                    title: "Virtual Microphone",
                    subtitle: micSubtitle,
                    state: micCardState,
                    statusText: micStatusText,
                    action: micAction
                )
                utilityRow
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear { setup.refreshAll() }
        .confirmationDialog(
            "Remove the LemurCam microphone?",
            isPresented: $showRemoveMic,
            titleVisibility: .visible
        ) {
            Button("Remove Microphone", role: .destructive) { setup.disableMicrophone() }
            Button("Cancel", role: .cancel) { showRemoveMic = false }
        } message: {
            Text("This uninstalls the audio component and briefly restarts audio. "
                + "You can re-enable it anytime without approving again.")
        }
    }

    private var utilityRow: some View {
        HStack {
            Button("Open Guided Setup\u{2026}") { openSetup?() }
            Spacer()
            Button("Re-check Now") { setup.refreshAll() }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Camera mapping

    private var cameraSubtitle: String {
        if case .failed(let message) = setup.cameraStatus { return message }
        return "LemurCam appears as a camera that apps like Zoom and FaceTime can select."
    }

    private var cameraCardState: SetupStepState {
        switch setup.cameraStatus {
        case .ready: return .ready
        case .installing, .unknown: return .working
        case .awaitingApproval, .disabled, .needsReboot, .needsAppRestart, .needsRepair, .notInstalled:
            return .actionNeeded
        case .failed: return .failed
        }
    }

    private var cameraStatusText: String {
        switch setup.cameraStatus {
        case .ready: return "Running"
        case .awaitingApproval: return "Needs approval"
        case .disabled: return "Turned off"
        case .needsReboot: return "Restart Mac"
        case .needsAppRestart: return "Restart app"
        case .needsRepair: return "Repair needed"
        case .installing, .unknown: return "Working\u{2026}"
        case .failed: return "Failed"
        case .notInstalled: return "Not enabled"
        }
    }

    private var cameraAction: AnyView? {
        switch setup.cameraStatus {
        case .ready, .needsReboot, .installing, .unknown:
            return nil
        case .needsAppRestart:
            return button("Restart LemurCam") { NSApp.relaunch() }
        case .awaitingApproval, .disabled:
            return button("Open System Settings") { setup.openCameraSystemSettings() }
        case .needsRepair:
            return button("Repair") { setup.repairCamera() }
        case .notInstalled:
            return button("Enable Camera") { setup.enableCamera() }
        case .failed:
            return button("Try Again") { setup.enableCamera() }
        }
    }

    // MARK: - Microphone mapping

    private var micSubtitle: String {
        if case .failed(let message) = setup.micStatus { return message }
        let base = "Optional — exposes your camera’s audio as a “LemurCam Microphone”."
        return setup.microphoneNeedsUpdate
            ? base + " A newer version is available — updating briefly restarts audio."
            : base
    }

    private var micCardState: SetupStepState {
        switch setup.micStatus {
        case .ready: return .ready
        case .installing, .unknown: return .working
        case .needsApproval: return .actionNeeded
        case .notSetUp: return .inactive
        case .failed: return .failed
        }
    }

    private var micStatusText: String {
        switch setup.micStatus {
        case .ready: return "Running"
        case .needsApproval: return "Needs approval"
        case .installing, .unknown: return "Working\u{2026}"
        case .notSetUp: return "Not set up"
        case .failed: return "Failed"
        }
    }

    private var micAction: AnyView? {
        switch setup.micStatus {
        case .ready:
            return AnyView(micManageButtons)
        case .installing, .unknown:
            return nil
        case .needsApproval:
            return button("Open System Settings") { setup.openMicrophoneSystemSettings() }
        case .notSetUp:
            return button("Enable Microphone") { setup.enableMicrophone() }
        case .failed:
            return button("Try Again") { setup.enableMicrophone() }
        }
    }

    @ViewBuilder
    private var micManageButtons: some View {
        HStack {
            if setup.microphoneNeedsUpdate {
                Button("Update Microphone") { setup.updateMicrophone() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Remove Microphone\u{2026}", role: .destructive) { showRemoveMic = true }
            Spacer(minLength: 0)
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> AnyView {
        AnyView(
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
        )
    }
}
