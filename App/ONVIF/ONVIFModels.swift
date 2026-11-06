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
        URLComponents(cameraURL: endpointURL)?.scheme?.lowercased() == "https"
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
    /// The request got no complete answer: the device is unreachable, refused the
    /// connection, did not answer in time or failed the TLS handshake, or its reply
    /// broke off. `code` is the URL Loading System's code for a request that got no
    /// reply at all, and nil once a reply had started arriving or when the error had
    /// no such code (see `isHostUnreachable`).
    case networkError(String, code: URLError.Code? = nil)
    /// The device answered with an HTTP error status (other than 401).
    case httpStatus(Int)
    case soapFault(String)
    case parseError
    case authenticationFailed
    case timedOut
    /// The camera's TLS certificate was refused (`ONVIFServerTrust`): macOS doesn't
    /// trust it, and it is not the one the user trusted for the camera, if any. The
    /// handshake failed, so nothing was sent.
    case certificateNotTrusted(ONVIFCertificateProblem)
    /// Not sent: the request would have gone over plain HTTP to `host`, which is
    /// outside the local network, and the user has not allowed that for the camera
    /// (`ONVIFLocalNetwork`).
    case plainHTTPRefused(host: String)

    /// True when no answer came back from the device at all, as opposed to the
    /// device answering with an error. Not the same as the host being out of reach
    /// (`isHostUnreachable`).
    var isTransportFailure: Bool {
        switch self {
        case .networkError, .timedOut:
            return true
        case .invalidURL, .httpStatus, .soapFault, .parseError, .authenticationFailed, .certificateNotTrusted,
             .plainHTTPRefused:
            return false
        }
    }

    /// Whether every further request to the device fails the same way: nothing
    /// answers, or only the user can clear the error. A fallback that sends another
    /// request (the default media path, the Mac's clock) is no use then.
    var failsEveryRequest: Bool {
        isTransportFailure || needsUserDecision
    }

    /// Whether only the user can clear the error, in the camera's settings: trying
    /// again, or looking for the camera elsewhere, would fail the same way.
    var needsUserDecision: Bool {
        switch self {
        case .certificateNotTrusted, .plainHTTPRefused:
            return true
        case .invalidURL, .networkError, .httpStatus, .soapFault, .parseError, .authenticationFailed, .timedOut:
            return false
        }
    }

    /// Whether no connection to the device's host could be made at all, which is what
    /// denied Local Network access looks like: only a request that got no reply and
    /// failed while connecting (`hostUnreachableCodes`). A transport failure is not
    /// enough. A timeout, whether the URL Loading System's or `timedOut` for a whole
    /// fetch, is the same for a connect that never finished and for a device that
    /// accepted the connection and never answered; a failed TLS handshake or an
    /// untrusted certificate came from a device that was reached; and so did a reply
    /// that broke off.
    var isHostUnreachable: Bool {
        guard case .networkError(_, let code?) = self else { return false }
        return Self.hostUnreachableCodes.contains(code)
    }

    /// The URL Loading System's codes for a request that could not connect to the
    /// device's host. With Local Network access denied, the system leaves the request
    /// no usable network path (its unsatisfied reason is
    /// `nw_path_unsatisfied_reason_local_network_denied`), which URLSession reports as
    /// `notConnectedToInternet`, as it does for any unsatisfied path; a connect that
    /// fails with no route to the host is `cannotConnectToHost`. A `.local` name that
    /// did not resolve, mDNS being gated by Local Network access too, is
    /// `cannotFindHost` (`dnsLookupFailed` is its older code). A refused connection
    /// and a host that is down are `cannotConnectToHost` as well, and count as they do
    /// for an RTSP camera (`RTSPStreamPipeline.isHostUnreachable`).
    private static let hostUnreachableCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ]

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ONVIF device URL"
        case .networkError(let msg, _):
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
        case .certificateNotTrusted, .plainHTTPRefused:
            return userDecisionDescription
        }
    }

    /// What the user has to decide, for an error only the user can clear.
    private var userDecisionDescription: String? {
        switch self {
        case .certificateNotTrusted(let problem):
            return problem.statusMessage
        case .plainHTTPRefused(let host):
            return "\(host) is outside your local network. "
                + "Use HTTPS, or turn on \(ONVIFLocalNetwork.allowanceName) for this camera."
        default:
            return nil
        }
    }
}
