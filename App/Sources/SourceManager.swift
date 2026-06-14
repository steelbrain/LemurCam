import Foundation
import os

@MainActor @Observable
internal final class SourceManager {
    private(set) var sources: [CameraSource] = []
    private(set) var activeSourceID: UUID?
    private(set) var connectionStatuses: [UUID: ConnectionStatus] = [:]
    private(set) var errorMessages: [UUID: String] = [:]

    var onSourceConfigChanged: (() -> Void)?

    private let storage: SourceStorage
    private let keychain: KeychainService

    init(storage: SourceStorage = SourceStorage(), keychain: KeychainService = KeychainService()) {
        self.storage = storage
        self.keychain = keychain
    }

    func load() {
        sources = storage.load()
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

    func addSource(name: String, sourceType: SourceType, credentials: SourceCredentials? = nil) {
        let (cleanType, urlCredentials) = Self.sanitizingCredentials(from: sourceType)
        let resolvedCredentials = credentials ?? urlCredentials
        let source = CameraSource(name: name, sourceType: cleanType)
        sources.append(source)
        connectionStatuses[source.id] = .disconnected

        if let resolvedCredentials {
            do {
                try keychain.save(credentials: resolvedCredentials, for: source.id)
            } catch {
                Log.app.error("Failed to save credentials for '\(name)': \(error)")
            }
        }

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

    func updateSource(id: UUID, name: String, sourceType: SourceType, credentials: SourceCredentials?) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }

        let (cleanType, urlCredentials) = Self.sanitizingCredentials(from: sourceType)
        let resolvedCredentials = credentials ?? urlCredentials

        var updated = sources[index]
        updated.name = name
        updated.sourceType = cleanType
        updated.updatedAt = Date()
        sources[index] = updated

        if let resolvedCredentials {
            do {
                try keychain.save(credentials: resolvedCredentials, for: id)
            } catch {
                Log.app.error("Failed to save credentials for '\(name)': \(error)")
            }
        } else {
            do {
                try keychain.delete(for: id)
            } catch {
                Log.app.error("Failed to delete credentials for source \(id): \(error)")
            }
        }

        persist()
        Log.app.info("Updated source '\(name)'")
        onSourceConfigChanged?()
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

    func credentials(for sourceID: UUID) -> SourceCredentials? {
        do {
            return try keychain.retrieve(for: sourceID)
        } catch {
            Log.app.error("Failed to retrieve credentials for source \(sourceID): \(error)")
            return nil
        }
    }

    func updateConnectionStatus(for sourceID: UUID, status: ConnectionStatus) {
        connectionStatuses[sourceID] = status
    }

    func updateErrorMessage(for sourceID: UUID, message: String?) {
        errorMessages[sourceID] = message
    }

    /// Strip credentials embedded in a `.rtsp` URL so they are never written to the
    /// persisted source JSON — they are routed to the Keychain instead. Enforced here,
    /// at the persistence boundary, so every caller (add, edit, future) is covered, not
    /// just the add-form's URL field. ONVIF sources are left untouched.
    private static func sanitizingCredentials(
        from sourceType: SourceType
    ) -> (SourceType, SourceCredentials?) {
        guard case .rtsp(let info) = sourceType else { return (sourceType, nil) }
        let (cleanedURL, credentials) = SourceCredentials.extractingFromRTSPURL(info.url)
        return (.rtsp(RTSPSourceInfo(url: cleanedURL)), credentials)
    }

    private func persist() {
        storage.save(sources)
        persistActiveSource()
    }

    private func persistActiveSource() {
        UserDefaults.standard.set(activeSourceID?.uuidString, forKey: LemurCamConfig.activeSourceKey)
    }
}
