import SwiftUI

internal struct GeneralSettingsView: View {
    var launchAtLoginManager: LaunchAtLoginManager
    /// Hands the camera the changed Resolution or Frame Rate
    /// (`StreamCoordinator.applyVirtualCameraFormat`).
    var onCameraFormatChange: () -> Void = {}
    @State private var selectedResolution = LemurCamConfig.storedResolution
    @State private var selectedFrameRate = LemurCamConfig.storedFrameRate

    var body: some View {
        Form {
            aboutSection
            launchAtLoginSection
            virtualCameraSection
        }
        .formStyle(.grouped)
        // Login Items can change in System Settings while Settings is closed.
        .onAppear { launchAtLoginManager.refresh() }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("LemurCam")
                        .font(.title2.bold())
                    Text("Version \(Bundle.main.shortVersion)")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("by")
                            .foregroundStyle(.secondary)
                        if let authorURL = URL(string: "https://aneesiqbal.ai") {
                            Link("Anees Iqbal", destination: authorURL)
                        }
                        Text("·")
                            .foregroundStyle(.secondary)
                        if let siteURL = URL(string: "https://lemur.cam") {
                            Link("lemur.cam", destination: siteURL)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var launchAtLoginSection: some View {
        Section {
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLoginManager.isEnabled },
                set: { launchAtLoginManager.setEnabled($0) }
            ))
        }
    }

    private var virtualCameraSection: some View {
        Section("Virtual Camera") {
            Picker("Resolution", selection: $selectedResolution) {
                ForEach(LemurCamConfig.Resolution.allCases) { res in
                    Text(res.rawValue).tag(res)
                }
            }
            .onChange(of: selectedResolution) { _, newValue in
                LemurCamConfig.storedResolution = newValue
                onCameraFormatChange()
            }

            Picker("Frame Rate", selection: $selectedFrameRate) {
                ForEach(LemurCamConfig.FrameRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .onChange(of: selectedFrameRate) { _, newValue in
                LemurCamConfig.storedFrameRate = newValue
                onCameraFormatChange()
            }

            Text(Self.formatCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What the two pickers do, as `SourceFormatState` implements it.
    static let formatCaption = """
        The LemurCam camera uses this format unless an app picks its own. \
        A change here applies right away, or once no app is using the camera. \
        A format an app picks stays until the next change.
        """
}
