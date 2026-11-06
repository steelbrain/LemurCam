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
    /// What Connect found at the URL, for a camera being added.
    @State private var resolvedType: SourceKind?
    /// The kind of the camera being edited.
    @State private var editSourceType: SourceKind?
    /// A certificate a fetch met that macOS doesn't trust, while the user is asked.
    @State private var trustPrompt: CertificateTrustPrompt?
    /// A device other than the camera being edited that Fetch Profiles reached, while
    /// the user is asked whether to use it.
    @State private var identityPrompt: DeviceIdentityPrompt?

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
        .certificateTrustDialog($trustPrompt, onTrust: trustCertificate)
        .deviceIdentityDialog($identityPrompt, onUse: useDevice, onCancel: keepSavedDevice)
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
                    onvifHost = ""
                    if resolvedType != nil {
                        resolvedType = nil
                        probeError = nil
                    }
                }
            if isProbing { probeProgressRow }
            if let probeError {
                Text(probeError).font(.caption).foregroundStyle(.red)
            }
            plainHTTPToggle
            onvifProfilePicker
            streamURILabel
        }
    }

    @ViewBuilder
    private func editSection(_ editType: SourceKind) -> some View {
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
            plainHTTPToggle
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
}

// MARK: - Rows

private extension SourceFormView {
    /// Shown for an ONVIF address outside the local network, once Connect read one.
    var plainHTTPToggle: some View {
        ONVIFPlainHTTPToggle(
            host: onvifHost, useHTTPS: onvifUseHTTPS, isOn: $onvifDetails.allowsPlainHTTPOutsideLocalNetwork
        )
    }

    var probeProgressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Connecting\u{2026}").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var onvifProfilePicker: some View {
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
    var streamURILabel: some View {
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
    enum SourceKind { case rtsp, onvif }
    typealias Address = SourceFormONVIFAddressEdits.Address

    /// The kind of camera the form saves: the edited camera's, or what Connect found.
    var sourceKind: SourceKind? {
        editing != nil ? editSourceType : resolvedType
    }

    var isValid: Bool {
        guard !name.isEmpty else { return false }
        switch sourceKind {
        case .rtsp: return isValidRTSPURL(inputText)
        case .onvif where editing != nil:
            return !onvifHost.isEmpty && ONVIFHostInput.problem(with: onvifHost) == nil
                && onvifDetails.selectedProfileToken != nil
                && onvifAddressEdits.allowsSave(at: onvifAddress)
        case .onvif: return onvifDetails.selectedProfileToken != nil
        case nil: return false
        }
    }

    func isValidRTSPURL(_ urlString: String) -> Bool {
        RTSPURLInput.problem(with: RTSPURLInput.normalized(urlString)) == nil
    }

    var onvifAddress: Address {
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
            useHTTPS: onvifUseHTTPS, policy: onvifDetails.connectionPolicy
        )
    }

    /// Trust in the certificate prompt: fetch again, accepting the certificate.
    func trustCertificate(_ prompt: CertificateTrustPrompt) {
        guard fetchTickets.isCurrent(prompt.ticket) else { return }
        onvifDetails.trust(prompt.problem.fingerprint)
        fetchProfiles()
    }

    /// A fetch failed: asks about a certificate macOS doesn't trust, or shows the error.
    func fetchFailed(_ error: any Error, ticket: Int) {
        if let prompt = CertificateTrustPrompt(error: error, ticket: ticket) {
            probeError = CertificateTrustPrompt.notTrustedMessage
            trustPrompt = prompt
        } else {
            probeError = error.localizedDescription
        }
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
        switch ONVIFURLInput.address(in: urlString) {
        case .failure(let problem):
            probeError = problem.message
        case .success(let address):
            let sameAddress = onvifAddress == .init(host: address.host, port: address.port, useHTTPS: address.useHTTPS)
            onvifHost = address.host
            onvifUseHTTPS = address.useHTTPS
            onvifPort = address.port
            // Connect is for the camera at this URL, which need not be the one before.
            onvifDetails.clear(keepingAddressDecisions: sameAddress)
            fetchProfiles()
        }
    }

    func fetchProfiles() {
        let ticket = fetchTickets.issue()
        isProbing = true
        probeError = nil
        onvifDetails.startFetchingProfiles()
        let address = onvifAddress
        let client = makeONVIFClient()
        SourceFormFetch.run {
            try await client.fetchDeviceDetails(includingEndpointReference: true)
        } then: { result in
            guard fetchTickets.isCurrent(ticket) else { return }
            isProbing = false
            switch result {
            case .success(let fetched): profilesFetched(fetched, at: address, ticket: ticket)
            case .failure(let error): fetchFailed(error, ticket: ticket)
            }
        }
    }

    /// Fetch Profiles worked. In the edit form, a device other than the camera being
    /// edited is used only once the user says so (`DeviceIdentityPrompt`).
    func profilesFetched(_ fetched: ONVIFDeviceDetails, at address: Address, ticket: Int) {
        guard let saved = savedONVIFInfo, onvifDetails.identity(of: fetched, saved: saved) == .different else {
            useFetchedDetails(fetched, at: address, adoptingIdentity: false)
            return
        }
        let prompt = DeviceIdentityPrompt(
            cameraName: name.isEmpty ? editing?.name ?? "" : name, address: address, fetched: fetched, ticket: ticket
        )
        probeError = prompt.notUsedMessage
        identityPrompt = prompt
    }

    func useFetchedDetails(_ fetched: ONVIFDeviceDetails, at address: Address, adoptingIdentity: Bool) {
        onvifAddressEdits.fetchSucceeded(at: address)
        onvifDetails.profilesFetched(fetched, adoptingIdentity: adoptingIdentity)
        resolvedType = .onvif
    }

    /// Use in the identity prompt: the device's profiles and identity, saved on Save.
    func useDevice(_ prompt: DeviceIdentityPrompt) {
        guard fetchTickets.isCurrent(prompt.ticket) else { return }
        probeError = nil
        useFetchedDetails(prompt.fetched, at: prompt.address, adoptingIdentity: true)
    }

    /// Cancel in the identity prompt: the camera as it was saved, at its saved address.
    func keepSavedDevice(_ prompt: DeviceIdentityPrompt) {
        guard fetchTickets.isCurrent(prompt.ticket), let saved = onvifAddressEdits.savedDetails(at: prompt.address)
        else { return }
        onvifDetails = SourceFormONVIFDetails(saved: saved)
    }

    func fetchStreamURI(profileToken: String) {
        let ticket = fetchTickets.issue()
        onvifDetails.startFetchingStreamURI()
        probeError = nil
        let client = makeONVIFClient()
        SourceFormFetch.run {
            try await client.getStreamURI(profileToken: profileToken)
        } then: { result in
            guard fetchTickets.isCurrent(ticket) else { return }
            switch result {
            case .success(let uri): onvifDetails.streamURIFetched(uri)
            case .failure(let error): fetchFailed(error, ticket: ticket)
            }
        }
    }

    func resolvedSourceType() -> SourceType? {
        switch sourceKind {
        case .rtsp: .rtsp(RTSPSourceInfo(url: RTSPURLInput.normalized(inputText)))
        case .onvif: .onvif(onvifDetails.sourceInfo(at: onvifAddress))
        case nil: nil
        }
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
        let outcome = store(name: name, sourceType: sourceType, credentials: change)
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
            let saved = SourceFormONVIFAddressEdits.SavedDetails(info)
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
