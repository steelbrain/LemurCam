import Foundation

/// A camera's username and password could not be stored in the Keychain. The camera
/// is then not added or changed: saving it anyway would keep a URL without the
/// credentials and lose the only copy of them.
internal struct CredentialSaveError: LocalizedError {
    var errorDescription: String? {
        "The username and password couldn't be saved in the Keychain, so the camera wasn't saved. Try again."
    }
}

/// Saving is refused for the session (`SourceStorage.SaveRefusal`), so no camera is
/// added, edited or removed. The Keychain would change while the saved file can't: a
/// removed camera would come back after a restart without its password, and an edited
/// one with its old one.
internal struct SaveRefusedError: LocalizedError {
    let refusal: SourceStorage.SaveRefusal

    var errorDescription: String? { refusal.message }
}

/// The cameras file could not be written, so a camera was not added, edited or
/// removed. The change is undone in the app and in the Keychain: kept only until the
/// app quits, a removed camera came back after a restart without its password, and an
/// edited one with its old address and its new password.
internal struct SourceFileSaveError: LocalizedError {
    var errorDescription: String? {
        "LemurCam couldn't save your cameras, so the change wasn't made. Try again."
    }
}

/// An edit was written to the cameras file, its new credentials couldn't be stored in
/// the Keychain, and the file couldn't be put back. The camera stays as edited, and its
/// old credentials are removed: they belong to the camera as it was, maybe another
/// address. Only when the Keychain can't remove them either do they stay.
internal struct EditSavedWithoutLoginError: LocalizedError {
    let oldLoginRemoved: Bool

    var errorDescription: String? {
        oldLoginRemoved
            ? "The camera was saved without its username and password: they couldn't be saved in the "
                + "Keychain, and the change couldn't be undone. Enter them again and save."
            : "The camera was saved, but its new username and password couldn't be saved in the Keychain, "
                + "and its old ones couldn't be removed. Enter them again and save, or delete the camera."
    }
}

@MainActor @Observable
internal final class SourceManager {
    private(set) var sources: [CameraSource] = []
    private(set) var activeSourceID: UUID?
    private(set) var connectionStatuses: [UUID: ConnectionStatus] = [:]
    private(set) var errorMessages: [UUID: String] = [:]
    /// The sources whose error message is about not reaching the camera's host at all
    /// (refused, no route, no answer), rather than an answer from the camera. Runtime
    /// state only, never saved; it goes with the error message.
    private(set) var unreachableSourceIDs: Set<UUID> = []
    /// Why camera changes are not being saved this session, or nil while saving
    /// works. Set by `load()`; shown in Settings → Cameras. Meanwhile adding, editing
    /// and removing cameras throws `SaveRefusedError`, and the active camera is not saved.
    private(set) var saveRefusal: SourceStorage.SaveRefusal?
    /// Whether the last save of the cameras failed (`SourceStorage.lastSaveFailed`).
    /// Cleared by the next save that works.
    private(set) var lastSaveFailed = false

    /// What Settings → Cameras shows above the list while cameras aren't being saved.
    var saveProblemMessage: String? {
        saveRefusal?.message ?? (lastSaveFailed ? SourceStorage.saveFailureMessage : nil)
    }

    var onSourceConfigChanged: (() -> Void)?

    private let storage: SourceStorage
    private let keychain: any CredentialStore

    init(storage: SourceStorage = SourceStorage(), keychain: any CredentialStore = KeychainService()) {
        self.storage = storage
        self.keychain = keychain
    }

    func load() {
        sources = storage.load()
        saveRefusal = storage.saveRefusal
        lastSaveFailed = storage.lastSaveFailed
        moveEmbeddedCredentialsToKeychain()
        for source in sources {
            connectionStatuses[source.id] = .disconnected
        }
        if let stored = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey),
           let id = UUID(uuidString: stored),
           sources.contains(where: { $0.id == id }) {
            activeSourceID = id
        } else {
            activeSourceID = sources.first?.id
        }
        Log.app.info("Loaded \(self.sources.count) source(s)")
    }

    /// Adds a camera. Throws, adding nothing, `SaveRefusedError` while saving is
    /// refused, `CredentialSaveError` when its credentials can't be stored, and
    /// `SourceFileSaveError` when the file can't be written. The credentials are stored
    /// first and deleted again when the write fails; were that to fail too, they belong
    /// to no saved camera.
    func addSource(name: String, sourceType: SourceType, credentials: SourceCredentials? = nil) throws {
        try checkChangesAllowed()
        let (cleanType, urlCredentials) = Self.sanitizingCredentials(from: sourceType)
        let resolvedCredentials = credentials ?? urlCredentials
        let source = CameraSource(name: name, sourceType: cleanType)

        if let resolvedCredentials {
            try storeCredentials(resolvedCredentials, for: source.id, sourceName: name)
        }

        let previous = sources
        let previousActiveID = activeSourceID
        sources.append(source)
        if activeSourceID == nil {
            activeSourceID = source.id
        }
        do {
            try saveChange(undoingTo: previous, activeSourceID: previousActiveID)
        } catch {
            if resolvedCredentials != nil { deleteCredentials(for: source.id) }
            throw error
        }

        connectionStatuses[source.id] = .disconnected
        Log.app.info("Added source '\(name)'")
        onSourceConfigChanged?()
    }

    /// Removes a camera and its stored credentials. Throws, removing nothing,
    /// `SaveRefusedError` while saving is refused, and `SourceFileSaveError` when the
    /// file can't be written. The file is written first, so a camera a failed write
    /// keeps also keeps its credentials.
    func removeSource(id: UUID) throws {
        try checkChangesAllowed()
        let previous = sources
        let previousActiveID = activeSourceID
        sources.removeAll { $0.id == id }
        if activeSourceID == id {
            activeSourceID = sources.first?.id
        }
        try saveChange(undoingTo: previous, activeSourceID: previousActiveID)

        connectionStatuses[id] = nil
        updateErrorMessage(for: id, message: nil)
        deleteCredentials(for: id)
        Log.app.info("Removed source \(id)")
        onSourceConfigChanged?()
    }

    /// Replaces a source's name and type and applies `credentials` to its stored
    /// credentials. Credentials embedded in an RTSP URL are moved to the Keychain and
    /// take precedence over `credentials`, even a `.set` of other ones, for the parts
    /// the URL holds (see `CredentialChange.merging`). Throws, changing nothing,
    /// `SaveRefusedError` while saving is refused, `CredentialSaveError` when new
    /// credentials can't be stored, or when the URL holds only part of a login and the
    /// stored part it needs can't be read, and `SourceFileSaveError` when the file
    /// can't be written. The file is written before the Keychain changes, so a failed
    /// write leaves the stored credentials with the camera as saved; credentials that
    /// then can't be stored put the file back as it was. When the file can't be put
    /// back either, the edit stays, without a login, and `EditSavedWithoutLoginError`
    /// is thrown (see `undoEdit`).
    ///
    /// `loaded` is the type the edit form loaded. An ONVIF address it left as it was
    /// gives way to one WS-Discovery saved since (`SourceType.keepingMove`); without
    /// `loaded`, `sourceType` replaces the saved type whole.
    func updateSource(
        id: UUID, name: String, sourceType: SourceType, credentials: CredentialChange,
        editedFrom loaded: SourceType? = nil
    ) throws {
        try checkChangesAllowed()
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }

        let (sanitizedType, _) = Self.sanitizingCredentials(from: sourceType)
        let savedType = sources[index].sourceType
        let cleanType = loaded.map { sanitizedType.keepingMove(savedSince: $0, now: savedType) } ?? sanitizedType
        if cleanType != sanitizedType {
            Log.app.info("Keeping the address found for '\(name)' while it was being edited")
        }
        let change = try credentialChange(credentials, mergingLoginFrom: sourceType, for: id, sourceName: name)

        let previous = sources
        var updated = sources[index]
        updated.name = name
        updated.sourceType = cleanType
        updated.updatedAt = Date()
        sources[index] = updated
        try saveChange(undoingTo: previous, activeSourceID: activeSourceID)
        do {
            try apply(change, for: id, sourceName: name)
        } catch {
            throw undoEdit(of: id, to: previous, sourceName: name, after: error)
        }

        Log.app.info("Updated source '\(name)'")
        onSourceConfigChanged?()
    }

    /// Shorthand for callers that always know the stored credentials: a value replaces
    /// them and nil removes them. Code that may not have read them (such as the edit
    /// form after a failed Keychain read) must pass a `CredentialChange` instead.
    func updateSource(id: UUID, name: String, sourceType: SourceType, credentials: SourceCredentials?) throws {
        try updateSource(
            id: id, name: name, sourceType: sourceType,
            credentials: credentials.map(CredentialChange.set) ?? .remove
        )
    }

    /// Records that an ONVIF camera now answers at the address of `moved` (found by
    /// WS-Discovery), as long as it is still saved at the address of `previous`, the one
    /// the resolve that found it started from. An address saved since, by an edit or by
    /// another resolve, is kept: the move was found for the address it replaced. An edit
    /// form opened before the move keeps it when saved (`SourceType.keepingMove`). Only
    /// the address changes, with a stored stream URI that named the old one
    /// (`SourceCredentials.storedStreamURI(_:movedFrom:to:)`): name, profile and
    /// credentials are left alone, nothing is written when the address is the same,
    /// and no config change is signalled, because the resolve that found the address
    /// goes on to connect there. `updatedAt` marks user edits and stays as it is.
    func updateONVIFAddress(id: UUID, from previous: ONVIFSourceInfo, to moved: ONVIFSourceInfo) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              case .onvif(var info) = sources[index].sourceType else { return }
        guard info.host == previous.host, info.port == previous.port, info.useHTTPS == previous.useHTTPS else {
            Log.app.info("Keeping the address saved for '\(sources[index].name)' since the camera was looked for")
            return
        }
        guard info.host != moved.host || info.port != moved.port || info.useHTTPS != moved.useHTTPS else { return }
        let oldHost = info.host
        info.streamURI = info.streamURI.flatMap {
            SourceCredentials.storedStreamURI($0, movedFrom: oldHost, to: moved.host)
        }
        info.host = moved.host
        info.port = moved.port
        info.useHTTPS = moved.useHTTPS
        sources[index].sourceType = .onvif(info)
        persist()
        Log.app.info("Camera '\(sources[index].name)' now answers at \(moved.host):\(moved.port)")
    }

    /// Only a failed save throws: a failed delete leaves the old credentials stored,
    /// which loses nothing.
    private func apply(_ change: CredentialChange, for id: UUID, sourceName: String) throws {
        switch change {
        case .keep:
            break
        case .set(let credentials):
            try storeCredentials(credentials, for: id, sourceName: sourceName)
        case .remove:
            deleteCredentials(for: id)
        }
    }

    private func storeCredentials(_ credentials: SourceCredentials, for id: UUID, sourceName: String) throws {
        do {
            try keychain.save(credentials: credentials, for: id)
        } catch {
            Log.app.error("Not saving '\(sourceName)': its credentials could not be stored (\(error))")
            throw CredentialSaveError()
        }
    }

    func setActiveSource(id: UUID?) {
        guard activeSourceID != id else { return }
        guard id == nil || sources.contains(where: { $0.id == id }) else { return }
        activeSourceID = id
        persistActiveSource()
        onSourceConfigChanged?()
    }

    func moveSource(from: IndexSet, to: Int) {
        sources.move(fromOffsets: from, toOffset: to)
        persist()
    }

    /// The stream URI saved with an ONVIF camera now, connected to when its stream URI
    /// can't be resolved. A move WS-Discovery saved rewrote it (`updateONVIFAddress`),
    /// so it can differ from the one the resolve started with. Nil when none is saved,
    /// or the source is not an ONVIF camera.
    func storedONVIFStreamURI(for sourceID: UUID) -> String? {
        guard case .onvif(let info)? = sources.first(where: { $0.id == sourceID })?.sourceType else { return nil }
        return info.streamURI
    }

    /// Credentials to connect with; nil when none are saved or they can't be read.
    /// Code that writes credentials back must use `loadCredentials(for:)` instead, so a
    /// failed read is never mistaken for "no authentication".
    func credentials(for sourceID: UUID) -> SourceCredentials? {
        try? loadCredentials(for: sourceID)
    }

    /// Nil when no credentials are saved for the source; throws when the Keychain
    /// can't be read.
    func loadCredentials(for sourceID: UUID) throws -> SourceCredentials? {
        do {
            return try keychain.retrieve(for: sourceID)
        } catch {
            Log.app.error("Failed to retrieve credentials for source \(sourceID): \(error)")
            throw error
        }
    }

    func updateConnectionStatus(for sourceID: UUID, status: ConnectionStatus) {
        connectionStatuses[sourceID] = status
    }

    /// `hostUnreachable`: the error is about not reaching the camera's host at all
    /// (see `unreachableSourceIDs`).
    func updateErrorMessage(for sourceID: UUID, message: String?, hostUnreachable: Bool = false) {
        errorMessages[sourceID] = message
        if message != nil, hostUnreachable {
            unreachableSourceIDs.insert(sourceID)
        } else {
            unreachableSourceIDs.remove(sourceID)
        }
    }

    private func persist() {
        saveSources()
        persistActiveSource()
    }

    private func saveSources() {
        storage.save(sources)
        lastSaveFailed = storage.lastSaveFailed
    }

    /// Not while saving is refused: the saved file lists last session's cameras, and
    /// the camera picked now need not be one of them.
    private func persistActiveSource() {
        guard saveRefusal == nil else { return }
        UserDefaults.standard.set(activeSourceID?.uuidString, forKey: LemurCamConfig.activeSourceKey)
    }
}

private extension SourceManager {
    func checkChangesAllowed() throws {
        if let saveRefusal { throw SaveRefusedError(refusal: saveRefusal) }
    }

    /// Writes the cameras after an add, edit or removal made in `sources`. When the
    /// file can't be written it still holds `previous`, so the cameras and the active
    /// camera go back to `previous` and `previousActiveID`, and `SourceFileSaveError`
    /// is thrown. `lastSaveFailed` stays as it was: what the app holds is again what it
    /// held before the change.
    func saveChange(undoingTo previous: [CameraSource], activeSourceID previousActiveID: UUID?) throws {
        guard storage.save(sources) else {
            sources = previous
            activeSourceID = previousActiveID
            Log.app.error("Undid a camera change: the cameras file could not be written")
            throw SourceFileSaveError()
        }
        lastSaveFailed = false
        persistActiveSource()
    }

    /// An edit is in the file and its new credentials couldn't be stored. Puts the
    /// cameras back to `previous`, in the app and in the file, and returns `error`. When
    /// the file can't be written, it keeps the edited camera, and with it the old
    /// credentials, which belong to the camera as it was: kept, they went to the edited
    /// address after a restart. They are removed instead, so the camera has no login
    /// rather than the wrong one; the app keeps the camera as the file has it, signals
    /// the change, and returns `EditSavedWithoutLoginError`.
    func undoEdit(of id: UUID, to previous: [CameraSource], sourceName: String, after error: any Error) -> any Error {
        let edited = sources
        sources = previous
        guard !storage.save(sources) else {
            lastSaveFailed = false
            return error
        }
        sources = edited
        // The file holds what the app holds: nothing is left unsaved.
        lastSaveFailed = false
        var oldLoginRemoved = true
        do {
            try keychain.delete(for: id)
        } catch {
            oldLoginRemoved = false
            Log.app.error("Failed to delete credentials for source \(id): \(error)")
        }
        Log.app.error("Saved '\(sourceName)' without its login: the edit could not be undone")
        onSourceConfigChanged?()
        return EditSavedWithoutLoginError(oldLoginRemoved: oldLoginRemoved)
    }

    /// Older versions could leave credentials inside saved URLs (an RTSP URL with an
    /// empty user name or with a `/`, `?`, `#` or `@` in its userinfo, or an ONVIF
    /// stream URI reported by the camera). Moves them out once on load: RTSP
    /// credentials go to the Keychain unless it already holds some for the source. If
    /// the Keychain can't be used, the URL is left as it is rather than losing the only
    /// copy of the credentials. So is an ambiguous URL (see
    /// `SourceCredentials.hasAmbiguousUserInfo`) whose source already has saved
    /// credentials: what it holds before its last `@` is only a reading, and may be
    /// part of the address rather than a login to drop. An ambiguous URL that
    /// `URLComponents` still reads as an address is never rewritten either: a login in
    /// the query (`rtsp://192.168.1.5:554/user=admin&password=p@ss`) would be split at
    /// the `@` in its password and the address lost. IPCamKit refuses such a URL with a
    /// message saying how to write the `@`, and the edit form asks for the same fix.
    func moveEmbeddedCredentialsToKeychain() {
        var migrated = 0
        for index in sources.indices {
            let source = sources[index]
            if Self.hasAmbiguousURLReadableAsAnAddress(source.sourceType) {
                Log.app.error("Left the saved URL of '\(source.name)' as it is: it can't be read reliably")
                continue
            }
            let (cleanType, urlCredentials) = Self.sanitizingCredentials(from: source.sourceType)
            guard cleanType != source.sourceType else { continue }
            if let urlCredentials {
                do {
                    if try keychain.retrieve(for: source.id) == nil {
                        try keychain.save(credentials: urlCredentials, for: source.id)
                    } else if case .rtsp(let info) = source.sourceType,
                              SourceCredentials.hasAmbiguousUserInfo(info.url) {
                        Log.app.error("Left the saved URL of '\(source.name)' as it is: it can't be read reliably")
                        continue
                    }
                } catch {
                    Log.app.error("Left credentials in the saved URL of '\(source.name)': Keychain unavailable")
                    continue
                }
            }
            sources[index].sourceType = cleanType
            migrated += 1
        }
        guard migrated > 0 else { return }
        saveSources()
        Log.app.info("Removed credentials from \(migrated) saved camera URL(s)")
    }

    /// A failed delete leaves credentials that no saved camera uses, or a camera's old
    /// ones, which loses nothing.
    func deleteCredentials(for id: UUID) {
        do {
            try keychain.delete(for: id)
        } catch {
            Log.app.error("Failed to delete credentials for source \(id): \(error)")
        }
    }

    /// `change` with the login an edited RTSP URL holds. A stored part that can't be
    /// read throws `CredentialSaveError`: saving without it would replace it with an
    /// empty one.
    func credentialChange(
        _ change: CredentialChange, mergingLoginFrom sourceType: SourceType, for id: UUID, sourceName: String
    ) throws -> CredentialChange {
        guard case .rtsp(let info) = sourceType else { return change }
        let login = SourceCredentials.extractingLoginFromRTSPURL(info.url).login
        do {
            return try change.merging(login) { try keychain.retrieve(for: id) }
        } catch {
            Log.app.error("Not saving '\(sourceName)': its stored credentials could not be read (\(error))")
            throw CredentialSaveError()
        }
    }

    /// Strip credentials embedded in source URLs so they are never written to the
    /// persisted source JSON. Enforced here, at the persistence boundary, so every
    /// caller (add, edit, load, future) is covered. Credentials from an `.rtsp` URL are
    /// returned to be routed to the Keychain. An `.onvif` stream URI comes from the
    /// camera, and some cameras put their RTSP login in it; that userinfo is dropped,
    /// since the URI is re-fetched from the camera on every connect and the stored
    /// copy is only a fallback. It is split at its last `@` only when that `@` ends a
    /// login (`SourceCredentials.strippingUserInfo(fromReportedURI:onvifHost:)`), so a
    /// login in its query (`?password=Adm1n@2024`) doesn't cost the address.
    static func sanitizingCredentials(
        from sourceType: SourceType
    ) -> (SourceType, SourceCredentials?) {
        switch sourceType {
        case .rtsp(let info):
            let (cleanedURL, credentials) = SourceCredentials.extractingFromRTSPURL(info.url)
            return (.rtsp(RTSPSourceInfo(url: cleanedURL)), credentials)
        case .onvif(var info):
            let host = info.host
            info.streamURI = info.streamURI.flatMap { uri in
                SourceCredentials.strippingUserInfo(fromReportedURI: uri, onvifHost: host)
            }
            return (.onvif(info), nil)
        }
    }

    /// Whether the saved RTSP URL or ONVIF stream URI has ambiguous userinfo (see
    /// `SourceCredentials.hasAmbiguousUserInfo`) yet parses as an address, so the part
    /// before its last `@` may well be address rather than login.
    static func hasAmbiguousURLReadableAsAnAddress(_ sourceType: SourceType) -> Bool {
        let url: String?
        switch sourceType {
        case .rtsp(let info): url = info.url
        case .onvif(let info): url = info.streamURI
        }
        guard let url, SourceCredentials.hasAmbiguousUserInfo(url) else { return false }
        return URLComponents(string: url) != nil
    }
}
