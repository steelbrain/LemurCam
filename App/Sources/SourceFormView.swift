import SwiftUI

internal struct SourceFormView: View {
    @Environment(\.dismiss) private var dismiss

    let sourceManager: SourceManager
    let editing: CameraSource?

    @State private var name: String = ""
    @State private var inputText: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var hasCredentials: Bool = false
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var onvifProfiles: [ONVIFProfile] = []
    @State private var selectedProfileToken: String?
    @State private var streamURI: String?
    @State private var onvifHost: String = ""
    @State private var onvifPort: Int = Tuning.defaultHTTPPort
    @State private var deviceUUID: String?
    @State private var resolvedType: ResolvedType?
    @State private var editSourceType: EditSourceType?

    init(sourceManager: SourceManager, editing: CameraSource? = nil) {
        self.sourceManager = sourceManager
        self.editing = editing
    }

    var body: some View {
        VStack(spacing: 0) {
            formContent
            footerButtons
        }
        .frame(width: 400)
        .onAppear {
            if let source = editing { populateFrom(source) }
        }
    }

    private var formContent: some View {
        Form {
            Section { TextField("Name", text: $name) }
            if editing != nil, let editType = editSourceType {
                editSection(editType)
            } else {
                addSection
            }
            credentialsSection
        }
        .formStyle(.grouped)
        .padding(.bottom, 0)
    }

    private var credentialsSection: some View {
        Section {
            Toggle("Requires Authentication", isOn: $hasCredentials)
            if hasCredentials {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if editing != nil {
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            } else {
                addModeButtons
            }
        }
        .padding()
    }

    private var addModeButtons: some View {
        HStack {
            Button("Connect") { connect() }
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || isProbing)
                .opacity(resolvedType != nil ? 0 : 1)
                .frame(width: resolvedType != nil ? 0 : nil)
            if resolvedType != nil {
                Button("Add") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
    }

    private var addSection: some View {
        Section {
            TextField("RTSP URL or ONVIF URL", text: $inputText)
                .textContentType(.URL)
                .onChange(of: inputText) { _, _ in
                    if resolvedType != nil {
                        resolvedType = nil
                        onvifProfiles = []
                        selectedProfileToken = nil
                        streamURI = nil
                        probeError = nil
                    }
                }
            if isProbing { probeProgressRow }
            if let probeError {
                Text(probeError).font(.caption).foregroundStyle(.red)
            }
            onvifProfilePicker
            streamURILabel
        }
    }

    @ViewBuilder
    private func editSection(_ editType: EditSourceType) -> some View {
        Section {
            switch editType {
            case .rtsp:
                TextField("RTSP URL", text: $inputText).textContentType(.URL)
            case .onvif:
                editONVIFFields
            }
        }
    }

    private var editONVIFFields: some View {
        Group {
            TextField("Host", text: $onvifHost)
            HStack {
                Text("Port")
                TextField("Port", value: $onvifPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
            }
            Button {
                fetchProfiles()
            } label: {
                HStack(spacing: 6) {
                    if isProbing { ProgressView().controlSize(.small) }
                    Text("Fetch Profiles")
                }
            }
            .disabled(onvifHost.isEmpty || isProbing)
            if let probeError {
                Text(probeError).font(.caption).foregroundStyle(.red)
            }
            onvifProfilePicker
            streamURILabel
        }
    }

    private var probeProgressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Connecting\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var onvifProfilePicker: some View {
        if !onvifProfiles.isEmpty {
            Picker("Profile", selection: $selectedProfileToken) {
                Text("Select a profile").tag(nil as String?)
                ForEach(onvifProfiles) { profile in
                    Text(profile.displayName).tag(profile.token as String?)
                }
            }
            .onChange(of: selectedProfileToken) { _, newToken in
                if let token = newToken { fetchStreamURI(profileToken: token) }
            }
        }
    }

    @ViewBuilder
    private var streamURILabel: some View {
        if let streamURI {
            LabeledContent("Stream URL") {
                Text(streamURI).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Types & Helpers

private extension SourceFormView {
    enum ResolvedType { case rtsp, onvif }
    enum EditSourceType { case rtsp, onvif }

    var isValid: Bool {
        guard !name.isEmpty else { return false }
        if editing != nil {
            switch editSourceType {
            case .rtsp: return isValidRTSPURL(inputText)
            case .onvif: return !onvifHost.isEmpty && selectedProfileToken != nil
            case nil: return false
            }
        }
        switch resolvedType {
        case .rtsp: return isValidRTSPURL(inputText)
        case .onvif: return selectedProfileToken != nil
        case nil: return false
        }
    }

    func isValidRTSPURL(_ urlString: String) -> Bool {
        guard !urlString.isEmpty,
              let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return false }
        return scheme == "rtsp" || scheme == "rtsps"
    }

    func makeONVIFClient() -> ONVIFClient {
        ONVIFClient(
            host: onvifHost, port: onvifPort,
            username: hasCredentials ? username : nil,
            password: hasCredentials ? password : nil
        )
    }

    func connect() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("rtsp://") || lower.hasPrefix("rtsps://") {
            handleDirectRTSP(trimmed)
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            handleDirectONVIF(trimmed)
        } else {
            probeError = "Enter an RTSP URL (rtsp://...) or ONVIF URL (http://...), or use Discover Cameras."
        }
    }

    func handleDirectRTSP(_ url: String) {
        if isValidRTSPURL(url) {
            resolvedType = .rtsp
            if var components = URLComponents(string: url) {
                if let user = components.user, !user.isEmpty {
                    username = user
                    password = components.password ?? ""
                    hasCredentials = true
                    components.user = nil
                    components.password = nil
                    if let cleaned = components.string { inputText = cleaned }
                }
                if name.isEmpty { name = components.host ?? "Camera" }
            }
        } else {
            probeError = "Enter a valid RTSP URL (e.g. rtsp://192.168.1.100:554/stream)"
        }
    }

    func handleDirectONVIF(_ urlString: String) {
        guard let components = URLComponents(string: urlString),
              let host = components.host, !host.isEmpty else {
            probeError = "Invalid ONVIF URL"
            return
        }
        onvifHost = host
        onvifPort = components.port
            ?? (components.scheme == "https" ? Tuning.defaultHTTPSPort : Tuning.defaultHTTPPort)
        fetchProfiles()
    }

    func fetchProfiles() {
        isProbing = true
        probeError = nil
        onvifProfiles = []
        selectedProfileToken = nil
        streamURI = nil
        let client = makeONVIFClient()
        Task {
            do {
                async let profilesResult = client.getProfiles()
                async let deviceInfoResult: ONVIFDeviceInfo? = {
                    try? await client.getDeviceInformation()
                }()
                let profiles = try await profilesResult
                let info = await deviceInfoResult
                await MainActor.run {
                    onvifProfiles = profiles
                    isProbing = false
                    resolvedType = .onvif
                    if let serial = info?.serialNumber, !serial.isEmpty { deviceUUID = serial }
                }
            } catch {
                await MainActor.run { probeError = error.localizedDescription; isProbing = false }
            }
        }
    }

    func fetchStreamURI(profileToken: String) {
        let client = makeONVIFClient()
        Task {
            do {
                let uri = try await client.getStreamURI(profileToken: profileToken)
                await MainActor.run { streamURI = uri }
            } catch {
                await MainActor.run { probeError = error.localizedDescription }
            }
        }
    }

    func resolvedSourceType() -> SourceType? {
        let useRTSP: Bool
        if editing != nil {
            switch editSourceType {
            case .rtsp:
                useRTSP = true
            case .onvif:
                useRTSP = false
            case nil: return nil
            }
        } else {
            switch resolvedType {
            case .rtsp:
                useRTSP = true
            case .onvif:
                useRTSP = false
            case nil: return nil
            }
        }
        if useRTSP {
            return .rtsp(RTSPSourceInfo(url: inputText))
        }
        return .onvif(ONVIFSourceInfo(
            deviceUUID: deviceUUID, host: onvifHost, port: onvifPort,
            selectedProfileToken: selectedProfileToken, streamURI: streamURI
        ))
    }

    func save() {
        guard let sourceType = resolvedSourceType() else { return }
        let credentials: SourceCredentials? =
            hasCredentials && !username.isEmpty
            ? SourceCredentials(username: username, password: password) : nil
        if let source = editing {
            sourceManager.updateSource(id: source.id, name: name,
                                       sourceType: sourceType, credentials: credentials)
        } else {
            sourceManager.addSource(name: name, sourceType: sourceType, credentials: credentials)
        }
    }

    func populateFrom(_ source: CameraSource) {
        name = source.name
        switch source.sourceType {
        case .rtsp(let info):
            editSourceType = .rtsp
            inputText = info.url
        case .onvif(let info):
            editSourceType = .onvif
            onvifHost = info.host
            onvifPort = info.port
            selectedProfileToken = info.selectedProfileToken
            streamURI = info.streamURI
            deviceUUID = info.deviceUUID
        }
        if let creds = sourceManager.credentials(for: source.id) {
            hasCredentials = true
            username = creds.username
            password = creds.password
        }
    }
}
