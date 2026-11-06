import Foundation

internal enum ConnectionStatus: String, Codable, Equatable {
    case pending
    case connecting
    case connected
    case disconnected
    case reconnecting
    case error
}

internal struct ONVIFSourceInfo: Codable, Equatable {
    var deviceUUID: String?
    var host: String
    var port: Int = 80
    var selectedProfileToken: String?
    var streamURI: String?
    /// Whether the device service is reached over HTTPS rather than HTTP.
    var useHTTPS = false
    /// The serial number from GetDeviceInformation. Kept apart from `deviceUUID`,
    /// which must be the WS-Discovery endpoint UUID for rediscovery to match.
    var serialNumber: String?
    /// The camera's certificate the user trusted for this address, accepted though
    /// macOS doesn't trust it (`ONVIFServerTrust`).
    var pinnedCertificate: CertificateFingerprint?
}

extension ONVIFSourceInfo {
    /// Decodes sources saved before a field existed: `useHTTPS`, `serialNumber` and
    /// `pinnedCertificate` were added later and default to HTTP, nil and nil when
    /// absent. `host` and `port` stay required. A pinned certificate that can't be read
    /// is dropped, so the camera's certificate is asked about again, rather than the
    /// whole cameras file failing to load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceUUID = try container.decodeIfPresent(String.self, forKey: .deviceUUID)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        selectedProfileToken = try container.decodeIfPresent(String.self, forKey: .selectedProfileToken)
        streamURI = try container.decodeIfPresent(String.self, forKey: .streamURI)
        useHTTPS = try container.decodeIfPresent(Bool.self, forKey: .useHTTPS) ?? false
        serialNumber = try container.decodeIfPresent(String.self, forKey: .serialNumber)
        pinnedCertificate = try? container.decodeIfPresent(CertificateFingerprint.self, forKey: .pinnedCertificate)
    }

    /// What a client for this camera may accept beyond what macOS allows on its own.
    var connectionPolicy: ONVIFConnectionPolicy {
        ONVIFConnectionPolicy(pinnedCertificate: pinnedCertificate)
    }

    /// Forgets the decisions the user made about the camera at its saved address,
    /// for a camera that now answers somewhere else: a certificate trusted at one
    /// address is not trusted at another without the user seeing it.
    mutating func clearAddressDecisions() {
        pinnedCertificate = nil
    }

    /// Takes the decisions saved with `other`, whose address these settings take.
    mutating func takeAddressDecisions(of other: Self) {
        pinnedCertificate = other.pinnedCertificate
    }

    /// The device UUID to keep after the form fetches a camera's details.
    ///
    /// Earlier versions of the form stored the serial number here, which never matches
    /// a WS-Discovery reply, and overwrote the real UUID of discovered cameras with it.
    /// A UUID that is not the serial (for example one from discovery) is kept. Otherwise
    /// the endpoint reference the device reports (GetEndpointReference, the same
    /// address WS-Discovery uses) replaces it, when there is one.
    static func resolvedDeviceUUID(current: String?, serialNumber: String?, endpointReference: String?) -> String? {
        let existing = current.flatMap { $0.isEmpty ? nil : $0 }
        if let existing, existing != serialNumber { return existing }
        return endpointReference ?? existing
    }
}

internal struct RTSPSourceInfo: Codable, Equatable {
    var url: String
}

internal enum SourceType: Codable, Equatable {
    case onvif(ONVIFSourceInfo)
    case rtsp(RTSPSourceInfo)
}

internal struct CameraSource: Identifiable, Equatable {
    let id: UUID
    var name: String
    var sourceType: SourceType
    var createdAt: Date
    var updatedAt: Date

    init(name: String, sourceType: SourceType,
         id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension CameraSource: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, sourceType, createdAt, updatedAt
    }
}
