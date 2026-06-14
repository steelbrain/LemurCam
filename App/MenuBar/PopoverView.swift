import SwiftUI

internal enum ExtensionState {
    case running
    case settingUp
    case notEnabled
    case needsReboot
    case needsAppRestart
    case needsRepair
}

internal struct PopoverView: View {
    var setup: SetupCoordinator?
    var sourceManager: SourceManager?
    var previewStore: PreviewStore?
    var openSettings: (() -> Void)?
    var openSetup: (() -> Void)?

    private var state: ExtensionState {
        switch setup?.cameraStatus {
        case .ready: return .running
        case .needsReboot: return .needsReboot
        case .needsAppRestart: return .needsAppRestart
        case .needsRepair: return .needsRepair
        case .installing, .unknown: return .settingUp
        case .awaitingApproval, .disabled, .notInstalled, .failed, .none:
            return .notEnabled
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch state {
            case .running:
                runningContent
            case .settingUp:
                settingUpView
            case .needsReboot:
                extensionIssueView(
                    title: "Extension Update Pending",
                    message: "Restart your Mac to complete\nthe extension update."
                )
            case .needsAppRestart:
                needsAppRestartView
            case .needsRepair:
                needsRepairView
            case .notEnabled:
                extensionDisabledView
            }
        }
        .frame(width: 300)
        .onAppear { setup?.refreshAll() }
    }

    // MARK: - Running

    @ViewBuilder
    private var runningContent: some View {
        if let sourceManager {
            topBar(sourceManager)
            previewArea(sourceManager)
            if localNetworkLikelyBlocked(sourceManager) {
                LocalNetworkWarningBanner()
            }
            statusBar(sourceManager)
        } else {
            Text("Initializing\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    // MARK: - Top Bar

    private func topBar(_ sourceManager: SourceManager) -> some View {
        HStack(spacing: 6) {
            if !sourceManager.sources.isEmpty {
                Picker("Camera", selection: Binding(
                    get: { sourceManager.activeSourceID },
                    set: { sourceManager.setActiveSource(id: $0) }
                )) {
                    Text("None").tag(nil as UUID?)
                    ForEach(sourceManager.sources) { source in
                        Text(source.name).tag(source.id as UUID?)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            Spacer()

            Button {
                openSettings?()
            } label: {
                Label("Settings", systemImage: "gear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Preview Area

    private func previewArea(_ sourceManager: SourceManager) -> some View {
        ZStack {
            // Black background
            Color.black

            if sourceManager.sources.isEmpty {
                // No cameras configured
                emptyStateMessage(
                    icon: "web.camera",
                    title: "No Camera Configured",
                    subtitle: "Add an IP camera in Settings\nto start streaming."
                )
            } else if sourceManager.activeSourceID == nil {
                // Cameras exist but none selected
                emptyStateMessage(
                    icon: "video.slash",
                    title: "No Camera Selected",
                    subtitle: "Select a camera above to\nstart streaming."
                )
            } else if let previewStore, let frame = previewStore.latestFrame {
                // Live preview
                Image(decorative: frame, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let activeID = sourceManager.activeSourceID,
                      let errorMsg = sourceManager.errorMessages[activeID] {
                // Error state
                emptyStateMessage(
                    icon: "exclamationmark.triangle",
                    title: "Connection Error",
                    subtitle: errorMsg
                )
            } else {
                // Connecting / no preview yet
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Connecting\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
    }

    private func emptyStateMessage(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.4))
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.white.opacity(0.7))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Local Network warning

    /// Heuristic: the active LAN camera errored, which on macOS is most often a
    /// denied/never-granted Local Network permission (there's no API to query it).
    private func localNetworkLikelyBlocked(_ sourceManager: SourceManager) -> Bool {
        guard let activeID = sourceManager.activeSourceID,
              let source = sourceManager.sources.first(where: { $0.id == activeID }) else {
            return false
        }
        let status = sourceManager.connectionStatuses[activeID] ?? .pending
        return LocalNetworkGuidance.isLikelyBlocked(
            host: LocalNetworkGuidance.host(for: source), status: status
        )
    }

    // MARK: - Status Bar

    private func statusBar(_ sourceManager: SourceManager) -> some View {
        HStack(spacing: 12) {
            if let activeID = sourceManager.activeSourceID {
                let status = sourceManager.connectionStatuses[activeID] ?? .disconnected
                HStack(spacing: 4) {
                    Circle()
                        .fill(connectionStatusColor(status))
                        .frame(width: 7, height: 7)
                    Text(connectionStatusLabel(status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let previewStore {
                    HStack(spacing: 8) {
                        if let width = previewStore.sourceWidth, let height = previewStore.sourceHeight {
                            Text("\(String(width))x\(String(height))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let fps = previewStore.estimatedFPS {
                            Text("\(fps) fps")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

}

// MARK: - Extension States

private extension PopoverView {
    var settingUpView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Setting Up LemurCam\u{2026}")
                .font(.headline)
            Button("Open Setup") { openSetup?() }
                .controlSize(.small)
        }
        .padding()
    }

    var extensionDisabledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("LemurCam Isn\u{2019}t Set Up")
                .font(.headline)
            Text("Finish setting up the LemurCam camera\nto start streaming.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Set Up LemurCam") { openSetup?() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    var needsAppRestartView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Almost Done")
                .font(.headline)
            Text("Restart LemurCam to finish setting up\nthe camera. Only the app restarts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Restart LemurCam") { NSApp.relaunch() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    var needsRepairView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Repair Needed")
                .font(.headline)
            Text("Multiple LemurCam camera extensions are\ninstalled. Repair to fix it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Repair") { setup?.repairCamera() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    func extensionIssueView(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
