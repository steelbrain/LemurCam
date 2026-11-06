import Foundation

/// Decides when a saved ONVIF camera should be looked for again with WS-Discovery,
/// and what to do with what the scan finds.
///
/// Rediscovery once saved the scan result even when the camera had not moved, and
/// saving fired a source-config change, which restarted the resolve, which failed
/// again: an endless loop of WS-Security logins, multicast scans and `sources.json`
/// rewrites that could lock the camera's account. An unmoved camera now saves nothing,
/// and saving a new address never signals a config change.
internal enum ONVIFRediscovery {
    enum Outcome: Equatable {
        /// No reply claimed the saved device UUID (or the source has none).
        case notFound
        /// Replies from more than one address claim the UUID; one may be an impostor.
        case ambiguous
        /// The device still answers at the saved address; nothing to save.
        case unchanged
        /// The device answers at a new address.
        case moved(ONVIFSourceInfo)
    }

    /// Whether the saved address may no longer be the camera's. After a DHCP change it
    /// can answer nothing at all (a transport failure), or belong to another device
    /// that answers with something other than this camera's ONVIF service: an HTTP
    /// error status, or a reply that is not a usable ONVIF document (a web page, an
    /// oversized or malformed body). A rejected login or a SOAP fault is the camera
    /// itself answering, so its address is right and no scan is made.
    static func shouldRediscover(after error: Error) -> Bool {
        if error is ONVIFXML.Rejection { return true }
        guard let onvifError = error as? ONVIFError else { return false }
        switch onvifError {
        case .networkError, .timedOut, .httpStatus, .parseError:
            return true
        case .invalidURL, .soapFault, .authenticationFailed:
            return false
        }
    }

    static func outcome(for info: ONVIFSourceInfo, among devices: [DiscoveredDevice]) -> Outcome {
        guard let uuid = info.deviceUUID, !uuid.isEmpty else { return .notFound }
        let matches = devices.filter { $0.endpointUUID == uuid }
        guard let device = matches.first else { return .notFound }
        guard Set(matches.map(Address.init(device:))).count == 1 else { return .ambiguous }
        guard Address(device: device) != Address(info: info) else { return .unchanged }

        var moved = info
        moved.host = device.host
        moved.port = device.port
        moved.useHTTPS = device.useHTTPS
        return .moved(moved)
    }

    private struct Address: Hashable {
        let host: String
        let port: Int
        let useHTTPS: Bool

        init(device: DiscoveredDevice) {
            host = Self.canonical(device.host)
            port = device.port
            useHTTPS = device.useHTTPS
        }

        init(info: ONVIFSourceInfo) {
            host = Self.canonical(info.host)
            port = info.port
            useHTTPS = info.useHTTPS
        }

        /// IP literals compare by value; host names compare case-insensitively.
        private static func canonical(_ host: String) -> String {
            ONVIFDiscovery.normalizedIPAddress(host) ?? host.lowercased()
        }
    }
}
