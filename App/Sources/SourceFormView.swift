import SwiftUI

internal struct SourceFormView: View {
    @Environment(\.dismiss) private var dismiss

    let sourceManager: SourceManager
    let editing: CameraSource?
    /// Called with what to tell the user when Save saved the camera with a problem
    /// (`SourceFormSaveOutcome.savedWithProblem`); the form then closes.
    let onSavedWithProblem: ((SavedEditProblem) -> Void)?

    @State private var name: String = ""
    @State private var inputText: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var hasCredentials: Bool = false
    /// Reading the saved credentials failed, so the form can't show them; saving
    /// leaves them untouched unless new ones are entered.
    @State private var credentialsUnreadable = false
    /// Why the last Save or Add did not save the camera; the form stays open.
    @State private var saveError: String?
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var onvifDetails = SourceFormONVIFDetails()
    @State private var onvifHost: String = ""
    @State private var onvifPort: Int = Tuning.defaultHTTPPort
    @State private var onvifUseHTTPS = false
    @State private var urlFieldEdits = SourceFormURLFieldEdits()
    @State private var fetchTickets = SourceFormFetchTickets()
    @State private var onvifAddressEdits = SourceFormONVIFAddressEdits()
    @State private var resolvedType: ResolvedType?
    @State private var editSourceType: EditSourceType?

    init(
        sourceManager: SourceManager, editing: CameraSource? = nil,
        onSavedWithProblem: ((SavedEditProblem) -> Void)? = nil
    ) {
        self.sourceManager = sourceManager
        self.editing = editing
        self.onSavedWithProblem = onSavedWithProblem
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
            if credentialsUnreadable {
                Text("The saved username and password couldn't be read from the Keychain. "
                     + "Saving keeps them unless you enter new ones here.")
                    .font(.caption).foregroundStyle(.red)
            }
            if hasCredentials {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if editing != nil {
                Button("Save") { if save() { dismiss() } }
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
                .disabled(RTSPURLInput.normalized(inputText).isEmpty || isProbing)
                .opacity(resolvedType != nil ? 0 : 1)
                .frame(width: resolvedType != nil ? 0 : nil)
            if resolvedType != nil {
                Button("Add") { if save() { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
    }

    private var addSection: some View {
        Section {
            TextField("RTSP URL or ONVIF URL", text: $inputText)
                .textContentType(.URL)
                .onChange(of: inputText) { _, newValue in
                    guard urlFieldEdits.isUserEdit(newValue) else { return }
                    // What is still being fetched, and what was read, is for the URL as it was.
                    fetchTickets.invalidate()
                    isProbing = false
                    onvifDetails.clear()
                    if resolvedType != nil {
                        resolvedType = nil
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
                if !inputText.isEmpty, let problem = RTSPURLInput.problem(with: RTSPURLInput.normalized(inputText)) {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            case .onvif:
                editONVIFFields
            }
        }
    }

    private var editONVIFFields: some View {
        Group {
            TextField("Host", text: $onvifHost)
            if let problem = ONVIFHostInput.problem(with: onvifHost) {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Port")
                TextField("Port", value: $onvifPort, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
            }
            Toggle("Use HTTPS", isOn: $onvifUseHTTPS)
            Button {
                fetchProfiles()
            } label: {
                HStack(spacing: 6) {
                    if isProbing { ProgressView().controlSize(.small) }
                    Text("Fetch Profiles")
                }
            }
            .disabled(onvifHost.isEmpty || isProbing || ONVIFHostInput.problem(with: onvifHost) != nil)
            if let probeError {
                Text(probeError).font(.caption).foregroundStyle(.red)
            } else if !isProbing, !onvifAddressEdits.allowsSave(at: onvifAddress) {
                Text("Fetch Profiles from the new address before saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            onvifProfilePicker
            streamURILabel
        }
        .onChange(of: onvifHost) { onvifAddressEdited() }
        .onChange(of: onvifPort) { onvifAddressEdited() }
        .onChange(of: onvifUseHTTPS) { onvifAddressEdited() }
    }

    private var probeProgressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Connecting\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var onvifProfilePicker: some View {
        if !onvifDetails.profiles.isEmpty {
            Picker("Profile", selection: $onvifDetails.selectedProfileToken) {
                Text("Select a profile").tag(nil as String?)
                ForEach(onvifDetails.profiles) { profile in
                    Text(profile.displayName).tag(profile.token as String?)
                }
            }
            .onChange(of: onvifDetails.selectedProfileToken) { _, newToken in
                if let token = newToken { fetchStreamURI(profileToken: token) }
            }
        }
    }

    @ViewBuilder
    private var streamURILabel: some View {
        if let streamURI = onvifDetails.streamURI {
            LabeledContent("Stream URL") {
                Text(DisplayedURL.redacted(streamURI))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
            case .onvif:
                return !onvifHost.isEmpty && ONVIFHostInput.problem(with: onvifHost) == nil
                    && onvifDetails.selectedProfileToken != nil
                    && onvifAddressEdits.allowsSave(at: onvifAddress)
            case nil: return false
            }
        }
        switch resolvedType {
        case .rtsp: return isValidRTSPURL(inputText)
        case .onvif: return onvifDetails.selectedProfileToken != nil
        case nil: return false
        }
    }

    func isValidRTSPURL(_ urlString: String) -> Bool {
        RTSPURLInput.problem(with: RTSPURLInput.normalized(urlString)) == nil
    }

    var onvifAddress: SourceFormONVIFAddressEdits.Address {
        .init(host: onvifHost, port: onvifPort, useHTTPS: onvifUseHTTPS)
    }

    /// Host, Port or Use HTTPS changed. What is still being fetched is for the
    /// address as it was, and details read from another address are cleared.
    func onvifAddressEdited() {
        fetchTickets.invalidate()
        isProbing = false
        switch onvifAddressEdits.addressEdited(to: onvifAddress) {
        case .keep:
            return
        case .clear:
            onvifDetails.clear()
        case .restore(let saved):
            onvifDetails = SourceFormONVIFDetails(saved: saved)
        }
        probeError = nil
    }

    func makeONVIFClient() -> ONVIFClient {
        ONVIFClient(
            host: onvifHost, port: onvifPort,
            username: hasCredentials ? username : nil,
            password: hasCredentials ? password : nil,
            useHTTPS: onvifUseHTTPS
        )
    }

    func connect() {
        let trimmed = RTSPURLInput.normalized(inputText)
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

    /// Moves any `user:password@` in the URL into the credential fields, including a
    /// password with an empty user name, so it is not kept in the URL; a part the URL
    /// lacks keeps what was typed (see `SourceFormCredentialFields`). The field then
    /// holds the URL as it will be saved: without the credentials and without the
    /// surrounding whitespace Connect ignored.
    func handleDirectRTSP(_ url: String) {
        if let problem = RTSPURLInput.problem(with: url) {
            probeError = problem
            return
        }
        resolvedType = .rtsp
        let (cleaned, login) = SourceCredentials.extractingLoginFromRTSPURL(url)
        var fields = SourceFormCredentialFields(isEnabled: hasCredentials, username: username, password: password)
        fields.take(login)
        hasCredentials = fields.isEnabled
        username = fields.username
        password = fields.password
        urlFieldEdits.replace(&inputText, with: cleaned)
        if name.isEmpty { name = URLComponents(string: cleaned)?.host ?? "Camera" }
    }

    func handleDirectONVIF(_ urlString: String) {
        guard let components = URLComponents(string: urlString),
              let host = components.host, !host.isEmpty else {
            probeError = "Invalid ONVIF URL"
            return
        }
        onvifHost = host
        onvifUseHTTPS = components.scheme?.lowercased() == "https"
        onvifPort = components.port ?? (onvifUseHTTPS ? Tuning.defaultHTTPSPort : Tuning.defaultHTTPPort)
        // Connect is for the camera at this URL, which need not be the one before.
        onvifDetails.clear()
        fetchProfiles()
    }

    func fetchProfiles() {
        let ticket = fetchTickets.issue()
        isProbing = true
        probeError = nil
        onvifDetails.startFetchingProfiles()
        let address = onvifAddress
        let client = makeONVIFClient()
        Task {
            do {
                let fetched = try await ONVIFTimeout.run(seconds: ONVIFTimeout.interactiveFetch) {
                    try await client.fetchDeviceDetails(includingEndpointReference: true)
                }
                await MainActor.run {
                    guard fetchTickets.isCurrent(ticket) else { return }
                    onvifAddressEdits.fetchSucceeded(at: address)
                    onvifDetails.profilesFetched(fetched)
                    isProbing = false
                    resolvedType = .onvif
                }
            } catch {
                await MainActor.run {
                    guard fetchTickets.isCurrent(ticket) else { return }
                    probeError = error.localizedDescription
                    isProbing = false
                }
            }
        }
    }

    func fetchStreamURI(profileToken: String) {
        let ticket = fetchTickets.issue()
        onvifDetails.startFetchingStreamURI()
        probeError = nil
        let client = makeONVIFClient()
        Task {
            do {
                let uri = try await ONVIFTimeout.run(seconds: ONVIFTimeout.interactiveFetch) {
                    try await client.getStreamURI(profileToken: profileToken)
                }
                await MainActor.run {
                    guard fetchTickets.isCurrent(ticket) else { return }
                    onvifDetails.streamURIFetched(uri)
                }
            } catch {
                await MainActor.run {
                    guard fetchTickets.isCurrent(ticket) else { return }
                    probeError = error.localizedDescription
                }
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
            return .rtsp(RTSPSourceInfo(url: RTSPURLInput.normalized(inputText)))
        }
        return .onvif(ONVIFSourceInfo(
            deviceUUID: onvifDetails.deviceUUID, host: onvifHost, port: onvifPort,
            selectedProfileToken: onvifDetails.selectedProfileToken, streamURI: onvifDetails.streamURI,
            useHTTPS: onvifUseHTTPS, serialNumber: onvifDetails.serialNumber
        ))
    }

    /// Saves the camera, and returns whether the form closes: it was saved. When it was
    /// not (its credentials could not be stored, say), `saveError` is set and the form
    /// stays open with what was entered. When it was saved with a problem, the form
    /// closes and `onSavedWithProblem` says what (see `SourceFormSaveOutcome`).
    func save() -> Bool {
        guard let sourceType = resolvedSourceType() else { return false }
        let change = CredentialChange.fromForm(
            authenticationEnabled: hasCredentials, username: username, password: password,
            storedCredentialsUnreadable: credentialsUnreadable
        )
        var failure: (any Error)?
        do {
            if let source = editing {
                // What the form loaded, so a move WS-Discovery saved since is kept. The
                // form closes once it saved the camera, so no save of its own came since.
                try sourceManager.updateSource(
                    id: source.id, name: name, sourceType: sourceType, credentials: change,
                    editedFrom: source.sourceType
                )
            } else {
                let credentials: SourceCredentials? = if case .set(let entered) = change { entered } else { nil }
                try sourceManager.addSource(name: name, sourceType: sourceType, credentials: credentials)
            }
        } catch {
            failure = error
        }
        let outcome = SourceFormSaveOutcome(error: failure)
        if case .notSaved(let message) = outcome { saveError = message }
        if case .savedWithProblem(let problem) = outcome { onSavedWithProblem?(problem) }
        return outcome.closesForm
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
            onvifUseHTTPS = info.useHTTPS
            let saved = SourceFormONVIFAddressEdits.SavedDetails(
                selectedProfileToken: info.selectedProfileToken, streamURI: info.streamURI,
                deviceUUID: info.deviceUUID, serialNumber: info.serialNumber
            )
            onvifDetails = SourceFormONVIFDetails(saved: saved)
            onvifAddressEdits = SourceFormONVIFAddressEdits(savedAt: onvifAddress, details: saved)
        }
        do {
            if let creds = try sourceManager.loadCredentials(for: source.id) {
                hasCredentials = true
                username = creds.username
                password = creds.password
            }
        } catch {
            credentialsUnreadable = true
        }
    }
}

/// Tells the user's edits of the URL field apart from the form rewriting it. Connect
/// moves `user:password@` out of an RTSP URL by rewriting the field; the field's
/// change handler resets the form after a user edit, and without this it also
/// treated the rewrite as one, undoing the Connect and hiding the Add button.
internal struct SourceFormURLFieldEdits {
    private var pendingRewrite: String?

    /// Call just before the form sets the field to `text` itself.
    mutating func rewrite(to text: String) {
        pendingRewrite = text
    }

    /// Sets `field` to `text` as the form's own change. Compares with what the field
    /// holds, so a URL that only lost its surrounding spaces is written back too.
    mutating func replace(_ field: inout String, with text: String) {
        guard field != text else { return }
        rewrite(to: text)
        field = text
    }

    /// Whether the field's new value came from the user.
    mutating func isUserEdit(_ newText: String) -> Bool {
        defer { pendingRewrite = nil }
        return pendingRewrite != newText
    }
}
