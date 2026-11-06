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
    @State private var selectedProfileToken: String?
    @State private var fetches = DiscoveryFetches()
    @State private var deviceUUID: String?
    @State private var cameraName = ""
    /// Why Save did not save the camera; the sheet stays open.
    @State private var saveError: String?

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
                Button("Back") { goBack(to: .scanning) }
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
            if fetches.isFetchingProfiles {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching profiles\u{2026}").foregroundStyle(.secondary)
                }
            }
            if let fetchError = fetches.error {
                Text(fetchError).font(.caption).foregroundStyle(.red)
            }
            if !fetches.profiles.isEmpty {
                Section {
                    Picker("Profile", selection: $selectedProfileToken) {
                        Text("Select a profile").tag(nil as String?)
                        ForEach(fetches.profiles) { profile in
                            Text(profile.displayName).tag(profile.token as String?)
                        }
                    }
                }
                if let streamURI = fetches.streamURI {
                    Section {
                        LabeledContent("Stream URL") {
                            Text(DisplayedURL.redacted(streamURI))
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
            Button("Back") { goBack(to: .credentials) }
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
                Section {
                    TextField("Camera Name", text: $cameraName)
                    if let saveError {
                        Text(saveError).font(.caption).foregroundStyle(.red)
                    }
                }
                if let device = selectedDevice {
                    Section("Details") {
                        LabeledContent("Host", value: "\(device.host):\(device.port)")
                        if let manufacturer = fetches.deviceInfo?.manufacturer {
                            LabeledContent("Manufacturer", value: manufacturer)
                        }
                        if let model = fetches.deviceInfo?.model {
                            LabeledContent("Model", value: model)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Back") { step = .profiles }
                Spacer()
                Button("Save") { if saveCamera() { dismiss() } }
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
        deviceUUID = device.endpointUUID
        username = ""
        password = ""
        hasCredentials = false
        dropFetches()
        step = .credentials
    }

    /// Back from the credentials or profiles step, whose fetches are for the camera
    /// and login entered before.
    private func goBack(to previous: Step) {
        dropFetches()
        step = previous
    }

    /// Drops the fetches in flight and what was fetched (see `DiscoveryFetches`).
    func dropFetches() {
        fetches.reset()
        selectedProfileToken = nil
    }

    func makeClient(for device: DiscoveredDevice) -> ONVIFClient {
        ONVIFClient(
            host: device.host, port: device.port,
            username: hasCredentials ? username : nil,
            password: hasCredentials ? password : nil,
            useHTTPS: device.useHTTPS
        )
    }

    func fetchDeviceProfiles() {
        guard let device = selectedDevice else { return }
        let ticket = fetches.startFetchingDetails()
        selectedProfileToken = nil
        step = .profiles
        let client = makeClient(for: device)
        Task {
            do {
                // Discovery already gave the device's endpoint UUID.
                let fetched = try await ONVIFTimeout.run(seconds: ONVIFTimeout.interactiveFetch) {
                    try await client.fetchDeviceDetails(includingEndpointReference: false)
                }
                await MainActor.run { fetches.detailsFetched(fetched, ticket: ticket) }
            } catch {
                await MainActor.run { fetches.fetchFailed(error.localizedDescription, ticket: ticket) }
            }
        }
    }

    func fetchStream(profileToken: String) {
        guard let device = selectedDevice else { return }
        let ticket = fetches.startFetchingStreamURI()
        let client = makeClient(for: device)
        Task {
            do {
                let uri = try await ONVIFTimeout.run(seconds: ONVIFTimeout.interactiveFetch) {
                    try await client.getStreamURI(profileToken: profileToken)
                }
                await MainActor.run { fetches.streamURIFetched(uri, ticket: ticket) }
            } catch {
                await MainActor.run { fetches.fetchFailed(error.localizedDescription, ticket: ticket) }
            }
        }
    }

    func prepareNaming() {
        if cameraName.isEmpty {
            if let name = selectedDevice?.name {
                cameraName = name
            } else if let manufacturer = fetches.deviceInfo?.manufacturer, let model = fetches.deviceInfo?.model {
                cameraName = "\(manufacturer) \(model)"
            } else if let manufacturer = selectedDevice?.manufacturer {
                cameraName = manufacturer
            } else {
                cameraName = "Camera"
            }
        }
        step = .naming
    }

    /// False, with `saveError` set, when the camera could not be saved.
    func saveCamera() -> Bool {
        guard let device = selectedDevice else { return false }
        let sourceType = SourceType.onvif(ONVIFSourceInfo(
            deviceUUID: deviceUUID, host: device.host, port: device.port,
            selectedProfileToken: selectedProfileToken, streamURI: fetches.streamURI, useHTTPS: device.useHTTPS,
            serialNumber: fetches.deviceInfo?.serialNumber.flatMap { $0.isEmpty ? nil : $0 }
        ))
        let credentials: SourceCredentials? =
            hasCredentials && !username.isEmpty
            ? SourceCredentials(username: username, password: password) : nil
        do {
            try sourceManager.addSource(name: cameraName, sourceType: sourceType, credentials: credentials)
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}
