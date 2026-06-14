import SwiftUI

internal struct DiscoveryView: View {
    @Environment(\.dismiss) private var dismiss

    let sourceManager: SourceManager

    @State private var step: Step = .scanning
    @State private var devices: [DiscoveredDevice] = []
    @State private var isScanning = false
    @State private var selectedDevice: DiscoveredDevice?
    @State private var username = ""
    @State private var password = ""
    @State private var hasCredentials = false
    @State private var profiles: [ONVIFProfile] = []
    @State private var selectedProfileToken: String?
    @State private var isFetchingProfiles = false
    @State private var fetchError: String?
    @State private var streamURI: String?
    @State private var deviceInfo: ONVIFDeviceInfo?
    @State private var deviceUUID: String?
    @State private var cameraName = ""

    private enum Step { case scanning, credentials, profiles, naming }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .scanning: scanningView
            case .credentials: credentialsView
            case .profiles: profilesView
            case .naming: namingView
            }
        }
        .frame(width: 400)
        .frame(minHeight: 300)
        .onAppear { startScan() }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 0) {
            scanningHeader
            Divider()
            scanningContent
            Divider()
            scanningFooter
        }
    }

    private var scanningHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Discover Cameras").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            if isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning network\u{2026}").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var scanningContent: some View {
        if devices.isEmpty && !isScanning {
            scanningEmptyState
        } else {
            scanningDeviceList
        }
    }

    private var scanningEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No cameras found").font(.subheadline)
            Text("Make sure your cameras are powered on\nand connected to the same network.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningDeviceList: some View {
        List(devices) { device in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name ?? "Unknown Camera").fontWeight(.medium)
                    HStack(spacing: 4) {
                        Text(device.host).font(.caption).foregroundStyle(.secondary)
                        if let manufacturer = device.manufacturer {
                            Text("\u{00B7}").foregroundStyle(.secondary)
                            Text(manufacturer).font(.caption).foregroundStyle(.secondary)
                        }
                        if let model = device.model {
                            Text(model).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { selectDevice(device) }
        }
    }

    private var scanningFooter: some View {
        HStack {
            Spacer()
            Button(isScanning ? "Scanning\u{2026}" : "Scan Again") { startScan() }
                .disabled(isScanning)
        }
        .padding()
    }

    // MARK: - Credentials

    private var credentialsView: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        Text("Connect to Camera").font(.headline)
                        Spacer()
                    }
                    Text("Enter credentials if required by \(selectedDevice?.name ?? "this camera").")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Requires Authentication", isOn: $hasCredentials)
                    if hasCredentials {
                        TextField("Username", text: $username)
                        SecureField("Password", text: $password)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Back") { step = .scanning }
                Spacer()
                Button("Connect") { fetchDeviceProfiles() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    // MARK: - Profiles

    private var profilesView: some View {
        VStack(spacing: 0) {
            profilesForm
            profilesFooter
        }
        .onChange(of: selectedProfileToken) { _, newToken in
            if let token = newToken { fetchStream(profileToken: token) }
        }
    }

    private var profilesForm: some View {
        Form {
            Section {
                HStack { Text("Select Profile").font(.headline); Spacer() }
            }
            if isFetchingProfiles {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching profiles\u{2026}").foregroundStyle(.secondary)
                }
            }
            if let fetchError {
                Text(fetchError).font(.caption).foregroundStyle(.red)
            }
            if !profiles.isEmpty {
                Section {
                    Picker("Profile", selection: $selectedProfileToken) {
                        Text("Select a profile").tag(nil as String?)
                        ForEach(profiles) { profile in
                            Text(profile.displayName).tag(profile.token as String?)
                        }
                    }
                }
                if let streamURI {
                    Section {
                        LabeledContent("Stream URL") {
                            Text(streamURI)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var profilesFooter: some View {
        HStack {
            Button("Back") { step = .credentials }
            Spacer()
            Button("Next") { prepareNaming() }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedProfileToken == nil)
        }
        .padding()
    }

}

// MARK: - Naming

private extension DiscoveryView {
    var namingView: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack { Text("Name Your Camera").font(.headline); Spacer() }
                }
                Section { TextField("Camera Name", text: $cameraName) }
                if let device = selectedDevice {
                    Section("Details") {
                        LabeledContent("Host", value: "\(device.host):\(device.port)")
                        if let manufacturer = deviceInfo?.manufacturer {
                            LabeledContent("Manufacturer", value: manufacturer)
                        }
                        if let model = deviceInfo?.model {
                            LabeledContent("Model", value: model)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Back") { step = .profiles }
                Spacer()
                Button("Save") { saveCamera(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cameraName.isEmpty)
            }
            .padding()
        }
    }
}

// MARK: - Actions

private extension DiscoveryView {
    func startScan() {
        isScanning = true
        devices = []
        let discovery = ONVIFDiscovery()
        Task {
            let found = await discovery.scan()
            await MainActor.run { devices = found; isScanning = false }
        }
    }

    func selectDevice(_ device: DiscoveredDevice) {
        selectedDevice = device
        deviceUUID = device.id
        username = ""
        password = ""
        hasCredentials = false
        step = .credentials
    }

    func makeClient(for device: DiscoveredDevice) -> ONVIFClient {
        ONVIFClient(
            host: device.host, port: device.port,
            username: hasCredentials ? username : nil,
            password: hasCredentials ? password : nil
        )
    }

    func fetchDeviceProfiles() {
        guard let device = selectedDevice else { return }
        isFetchingProfiles = true
        fetchError = nil
        profiles = []
        selectedProfileToken = nil
        streamURI = nil
        step = .profiles
        let client = makeClient(for: device)
        Task {
            async let profilesResult = client.getProfiles()
            async let deviceInfoResult: ONVIFDeviceInfo? = {
                try? await client.getDeviceInformation()
            }()
            do {
                let fetchedProfiles = try await profilesResult
                let info = await deviceInfoResult
                await MainActor.run {
                    profiles = fetchedProfiles; deviceInfo = info; isFetchingProfiles = false
                }
            } catch {
                await MainActor.run { fetchError = error.localizedDescription; isFetchingProfiles = false }
            }
        }
    }

    func fetchStream(profileToken: String) {
        guard let device = selectedDevice else { return }
        let client = makeClient(for: device)
        Task {
            do {
                let uri = try await client.getStreamURI(profileToken: profileToken)
                await MainActor.run { streamURI = uri }
            } catch {
                await MainActor.run { fetchError = error.localizedDescription }
            }
        }
    }

    func prepareNaming() {
        if cameraName.isEmpty {
            if let name = selectedDevice?.name {
                cameraName = name
            } else if let manufacturer = deviceInfo?.manufacturer, let model = deviceInfo?.model {
                cameraName = "\(manufacturer) \(model)"
            } else if let manufacturer = selectedDevice?.manufacturer {
                cameraName = manufacturer
            } else {
                cameraName = "Camera"
            }
        }
        step = .naming
    }

    func saveCamera() {
        guard let device = selectedDevice else { return }
        let sourceType = SourceType.onvif(ONVIFSourceInfo(
            deviceUUID: deviceUUID, host: device.host, port: device.port,
            selectedProfileToken: selectedProfileToken, streamURI: streamURI
        ))
        let credentials: SourceCredentials? =
            hasCredentials && !username.isEmpty
            ? SourceCredentials(username: username, password: password) : nil
        sourceManager.addSource(name: cameraName, sourceType: sourceType, credentials: credentials)
    }
}
