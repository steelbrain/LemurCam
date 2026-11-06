import Foundation

internal struct DiscoveredDevice: Identifiable {
    let endpointUUID: String // From wsa:Address, without "urn:uuid:"
    let endpointURL: String  // Chosen XAddr (the device service URL), on the replying host
    let name: String?        // Parsed from scopes (onvif://www.onvif.org/name/...)
    let manufacturer: String? // From scopes
    let model: String?       // From scopes
    let host: String         // The host the reply came from
    let port: Int            // Extracted from endpoint URL

    /// Two replies can claim the same endpoint UUID (a device and an impostor), so a
    /// device is identified by its UUID and address together.
    var id: String { "\(endpointUUID)@\(host):\(port)" }

    /// Whether the device service URL is HTTPS.
    var useHTTPS: Bool {
        URLComponents(string: endpointURL)?.scheme?.lowercased() == "https"
    }
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
    /// The request got no answer: the device is unreachable, refused the
    /// connection, or the TLS handshake failed.
    case networkError(String)
    /// The device answered with an HTTP error status (other than 401).
    case httpStatus(Int)
    case soapFault(String)
    case parseError
    case authenticationFailed
    case timedOut

    /// True when no answer came back from the device at all, as opposed to the
    /// device answering with an error. Only these suggest the device may have moved.
    var isTransportFailure: Bool {
        switch self {
        case .networkError, .timedOut:
            return true
        case .invalidURL, .httpStatus, .soapFault, .parseError, .authenticationFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ONVIF device URL"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .httpStatus(let code):
            return "Network error: HTTP \(code)"
        case .soapFault(let msg):
            return "ONVIF error: \(msg)"
        case .parseError:
            return "Failed to parse ONVIF response"
        case .authenticationFailed:
            return "Authentication failed"
        case .timedOut:
            return "The camera did not respond in time"
        }
    }
}
