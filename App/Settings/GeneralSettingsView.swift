import SwiftUI

internal struct GeneralSettingsView: View {
    var launchAtLoginManager: LaunchAtLoginManager
    /// Hands the camera the changed Resolution or Frame Rate
    /// (`StreamCoordinator.applyVirtualCameraFormat`).
    var onCameraFormatChange: () -> Void = {}
    /// Hands the stream the changed Video Buffer (`StreamCoordinator.videoBuffer`).
    var onVideoBufferChange: (VideoBufferSetting) -> Void = { _ in }
    @State private var selectedResolution = LemurCamConfig.storedResolution
    @State private var selectedFrameRate = LemurCamConfig.storedFrameRate
    @State private var selectedVideoBuffer = VideoBufferStore().setting

    var body: some View {
        Form {
            aboutSection
            launchAtLoginSection
            virtualCameraSection
            videoBufferSection
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

    private var videoBufferSection: some View {
        Section("Advanced") {
            LabeledContent("Video Buffer") {
                HStack {
                    Picker("Video Buffer", selection: $selectedVideoBuffer) {
                        ForEach(VideoBufferSetting.allCases) { setting in
                            Text(setting.label).tag(setting)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Button("Reset") {
                        VideoBufferStore().reset()
                        selectedVideoBuffer = .defaultValue
                    }
                    .disabled(selectedVideoBuffer == .defaultValue)
                    .help("Go back to the default, \(VideoBufferSetting.defaultValue.label)")
                }
            }
            .onChange(of: selectedVideoBuffer) { _, newValue in
                // After Reset the store already reads as the default: nothing to save.
                let store = VideoBufferStore()
                if store.setting != newValue { store.setting = newValue }
                onVideoBufferChange(newValue)
            }

            Text(Self.videoBufferCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What the Video Buffer picker does, as `JitterBuffer` implements it.
    static let videoBufferCaption = """
        LemurCam holds this much of the camera's video before sending it on, which \
        smooths over short pauses in the camera's video. Less buffer means less delay, \
        and pauses show as stutters. Off sends each frame on as soon as it's decoded. \
        Lower it if the picture lags behind a separate microphone.
        """

    /// What the two pickers do, as `SourceFormatState` implements it.
    static let formatCaption = """
        The LemurCam camera uses this format unless an app picks its own. \
        A change here applies right away, or once no app is using the camera. \
        A format an app picks stays until the next change.
        """
}
