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
