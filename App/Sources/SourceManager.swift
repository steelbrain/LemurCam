import Foundation
import os

/// A camera's username and password could not be stored in the Keychain. The camera
/// is then not added or changed: saving it anyway would keep a URL without the
/// credentials and lose the only copy of them.
internal struct CredentialSaveError: LocalizedError {
    var errorDescription: String? {
        "The username and password couldn't be saved in the Keychain, so the camera wasn't saved. Try again."
    }
}

@MainActor @Observable
internal final class SourceManager {
    private(set) var sources: [CameraSource] = []
    private(set) var activeSourceID: UUID?
    private(set) var connectionStatuses: [UUID: ConnectionStatus] = [:]
    private(set) var errorMessages: [UUID: String] = [:]
    /// Why camera changes are not being saved this session, or nil while saving
    /// works. Set by `load()`; shown in Settings → Cameras.
    private(set) var saveRefusal: SourceStorage.SaveRefusal?

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

    /// Adds a camera. Throws `CredentialSaveError`, adding nothing, when its
    /// credentials can't be stored.
    func addSource(name: String, sourceType: SourceType, credentials: SourceCredentials? = nil) throws {
        let (cleanType, urlCredentials) = Self.sanitizingCredentials(from: sourceType)
        let resolvedCredentials = credentials ?? urlCredentials
        let source = CameraSource(name: name, sourceType: cleanType)

        if let resolvedCredentials {
            try storeCredentials(resolvedCredentials, for: source.id, sourceName: name)
        }

        sources.append(source)
        connectionStatuses[source.id] = .disconnected
        if activeSourceID == nil {
            activeSourceID = source.id
        }

        persist()
        Log.app.info("Added source '\(name)'")
        onSourceConfigChanged?()
    }

    func removeSource(id: UUID) {
        sources.removeAll { $0.id == id }
        connectionStatuses[id] = nil
        errorMessages[id] = nil
        do {
            try keychain.delete(for: id)
        } catch {
            Log.app.error("Failed to delete credentials for source \(id): \(error)")
        }

        if activeSourceID == id {
            activeSourceID = sources.first?.id
        }

        persist()
        Log.app.info("Removed source \(id)")
        onSourceConfigChanged?()
    }

    /// Replaces a source's name and type and applies `credentials` to its stored
    /// credentials. Credentials embedded in an RTSP URL are moved to the Keychain and
    /// take precedence over `credentials`, even a `.set` of other ones: the edit form
    /// shows the saved URL without credentials and fills the fields with the saved
    /// ones, so a login in the URL was just typed or pasted and is the newest input.
    /// Throws `CredentialSaveError`, changing nothing, when new credentials can't be
    /// stored.
    func updateSource(id: UUID, name: String, sourceType: SourceType, credentials: CredentialChange) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }

        let (cleanType, urlCredentials) = Self.sanitizingCredentials(from: sourceType)
        let change = urlCredentials.map(CredentialChange.set) ?? credentials
        try apply(change, for: id, sourceName: name)

        var updated = sources[index]
        updated.name = name
        updated.sourceType = cleanType
        updated.updatedAt = Date()
        sources[index] = updated

        persist()
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

    /// Records that an ONVIF camera now answers at a new address (found by
    /// WS-Discovery). Only the address changes: name, profile and credentials are left
    /// alone, nothing is written when the address is the same, and no config change is
    /// signalled, because the resolve that found the address goes on to connect there.
    /// `updatedAt` marks user edits and stays as it is.
    func updateONVIFAddress(id: UUID, host: String, port: Int, useHTTPS: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              case .onvif(var info) = sources[index].sourceType,
              info.host != host || info.port != port || info.useHTTPS != useHTTPS else { return }
        info.host = host
        info.port = port
        info.useHTTPS = useHTTPS
        sources[index].sourceType = .onvif(info)
        persist()
        Log.app.info("Camera '\(sources[index].name)' now answers at \(host):\(port)")
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
            do {
                try keychain.delete(for: id)
            } catch {
                Log.app.error("Failed to delete credentials for source \(id): \(error)")
            }
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

    func updateErrorMessage(for sourceID: UUID, message: String?) {
        errorMessages[sourceID] = message
    }

    /// Strip credentials embedded in source URLs so they are never written to the
    /// persisted source JSON. Enforced here, at the persistence boundary, so every
    /// caller (add, edit, load, future) is covered. Credentials from an `.rtsp` URL are
    /// returned to be routed to the Keychain. An `.onvif` stream URI comes from the
    /// camera, and some cameras put their RTSP login in it; that userinfo is dropped,
    /// since the URI is re-fetched from the camera on every connect and the stored
    /// copy is only a fallback.
    private static func sanitizingCredentials(
        from sourceType: SourceType
    ) -> (SourceType, SourceCredentials?) {
        switch sourceType {
        case .rtsp(let info):
            let (cleanedURL, credentials) = SourceCredentials.extractingFromRTSPURL(info.url)
            return (.rtsp(RTSPSourceInfo(url: cleanedURL)), credentials)
        case .onvif(var info):
            info.streamURI = info.streamURI.map(SourceCredentials.strippingUserInfo(from:))
            return (.onvif(info), nil)
        }
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
    private func moveEmbeddedCredentialsToKeychain() {
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
        storage.save(sources)
        Log.app.info("Removed credentials from \(migrated) saved camera URL(s)")
    }

    /// Whether the saved RTSP URL or ONVIF stream URI has ambiguous userinfo (see
    /// `SourceCredentials.hasAmbiguousUserInfo`) yet parses as an address, so the part
    /// before its last `@` may well be address rather than login.
    private static func hasAmbiguousURLReadableAsAnAddress(_ sourceType: SourceType) -> Bool {
        let url: String?
        switch sourceType {
        case .rtsp(let info): url = info.url
        case .onvif(let info): url = info.streamURI
        }
        guard let url, SourceCredentials.hasAmbiguousUserInfo(url) else { return false }
        return URLComponents(string: url) != nil
    }

    private func persist() {
        storage.save(sources)
        persistActiveSource()
    }

    private func persistActiveSource() {
        UserDefaults.standard.set(activeSourceID?.uuidString, forKey: LemurCamConfig.activeSourceKey)
    }
}
