import Foundation

internal struct DiscoveredDevice: Identifiable {
    let id: String           // UUID from wsa:Address
    let endpointURL: String  // XAddrs (the ONVIF service URL)
    let name: String?        // Parsed from scopes (onvif://www.onvif.org/name/...)
    let manufacturer: String? // From scopes
    let model: String?       // From scopes
    let host: String         // Extracted from endpoint URL
    let port: Int            // Extracted from endpoint URL
}

internal struct ONVIFDeviceInfo {
    let manufacturer: String?
    let model: String?
    let firmwareVersion: String?
    let serialNumber: String?
    let hardwareId: String?
}

internal struct ONVIFProfile: Identifiable, Equatable {
    let token: String
    let name: String
    let width: Int?
    let height: Int?
    let codec: String?

    var id: String { token }

    var displayName: String {
        var parts = [name]
        if let width, let height {
            parts.append("\(width)x\(height)")
        }
        if let codec {
            parts.append(codec)
        }
        return parts.joined(separator: " ")
    }
}

internal enum ONVIFError: LocalizedError {
    case invalidURL
    case networkError(String)
    case soapFault(String)
    case parseError
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ONVIF device URL"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .soapFault(let msg):
            return "ONVIF error: \(msg)"
        case .parseError:
            return "Failed to parse ONVIF response"
        case .authenticationFailed:
            return "Authentication failed"
        }
    }
}
