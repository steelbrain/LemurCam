import Foundation

/// Decides when a saved ONVIF camera should be looked for again with WS-Discovery,
/// and what to do with what the scan finds.
///
/// Rediscovery used to run after any failed GetStreamUri and to save the scan result
/// even when the camera had not moved. Saving fired a source-config change, which
/// restarted the resolve, which failed again: an endless loop of WS-Security logins,
/// multicast scans and `sources.json` rewrites that could lock the camera's account.
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

    /// Only a request that got no answer at all suggests the camera moved. An answer
    /// such as a rejected login, a SOAP fault or an HTTP error means it was reached at
    /// the saved address.
    static func shouldRediscover(after error: Error) -> Bool {
        (error as? ONVIFError)?.isTransportFailure ?? false
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
