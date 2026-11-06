import Darwin

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

    /// Whether the saved address `info` may no longer be the camera's. After a DHCP
    /// change it can answer nothing at all (a transport failure), or belong to another
    /// device that answers with something other than this camera's ONVIF service: an
    /// HTTP error status, or a reply that is not a usable ONVIF document (a web page, an
    /// oversized or malformed body).
    ///
    /// A rejected login or a SOAP fault can come from the camera itself, but also from
    /// another ONVIF camera: after a router reset two cameras can swap addresses, and
    /// this camera's login then went to the other one on every retry (which can lock
    /// its account) and was never looked for again. So these lead to a scan too when
    /// the camera can be looked for (it has a device UUID) and is saved by its LAN IP
    /// address, the kind DHCP reassigns. A scan sends no login, and a camera it finds
    /// at the saved address leaves everything as it is.
    static func shouldRediscover(after error: Error, at info: ONVIFSourceInfo) -> Bool {
        if error is ONVIFXML.Rejection { return true }
        guard let onvifError = error as? ONVIFError else { return false }
        switch onvifError {
        case .networkError, .timedOut, .httpStatus, .parseError:
            return true
        case .soapFault, .authenticationFailed:
            guard let uuid = info.deviceUUID, !uuid.isEmpty else { return false }
            return isLANAddress(info.host)
        case .invalidURL, .certificateNotTrusted, .plainHTTPRefused, .differentDevice:
            return false
        }
    }

    /// Whether a move found after `error` at the saved address is saved only once the
    /// camera gave its stream URI at the new address. After a rejected login or a SOAP
    /// fault the saved address still answers, maybe as this camera itself, and the scan
    /// reply that matched may come from another device claiming the same UUID (cloned
    /// firmware) while the camera's own reply was lost: saved at once, the source was
    /// re-pointed for good, and could flip between the two on retries. After a
    /// transport failure, or an answer that is not this camera's ONVIF service,
    /// nothing at the saved address is the camera, so the move is saved before asking.
    static func savesMoveOnlyOnceAnswered(after error: Error) -> Bool {
        guard let onvifError = error as? ONVIFError else { return false }
        switch onvifError {
        case .soapFault, .authenticationFailed:
            return true
        case .networkError, .timedOut, .httpStatus, .parseError, .invalidURL, .certificateNotTrusted,
             .plainHTTPRefused, .differentDevice:
            return false
        }
    }

    static func outcome(for info: ONVIFSourceInfo, among devices: [DiscoveredDevice]) -> Outcome {
        guard let uuid = info.deviceUUID, !uuid.isEmpty else { return .notFound }
        let matches = devices.filter { $0.endpointUUID == uuid }
        guard let device = matches.first else { return .notFound }
        guard Set(matches.map(Address.init(device:))).count == 1 else { return .ambiguous }

        let found = settings(for: info, at: device)
        guard Address(info: found) != Address(info: info) else { return .unchanged }
        return .moved(found)
    }

    /// Whether a move is saved, or the found address is used for this connection
    /// only. A camera saved by its LAN IP address moves when its DHCP lease changes, so
    /// the new address is saved. A host name (`cam.local`, a DDNS name), a loopback
    /// address (an SSH tunnel) or a public address reached through port forwarding is
    /// what the user entered and keeps working where the LAN address the scan found
    /// does not, so it is never overwritten. Nor is HTTPS ever replaced by HTTP.
    static func shouldSave(_ moved: ONVIFSourceInfo, replacing saved: ONVIFSourceInfo) -> Bool {
        isLANAddress(saved.host) && (moved.useHTTPS || !saved.useHTTPS)
    }

    /// Whether `host` is an IP literal in a range that addresses a device on the local
    /// network: private IPv4 (10/8, 172.16/12, 192.168/16), link-local (169.254/16,
    /// fe80::/10) or IPv6 unique local (fc00::/7). Host names and every other address
    /// are not, including carrier-grade NAT (100.64/10) and loopback (127/8, ::1): a
    /// camera saved as `127.0.0.1:8080` is reached through an SSH tunnel or a port
    /// forward, not at a LAN address of its own.
    static func isLANAddress(_ host: String) -> Bool {
        guard let literal = ONVIFDiscovery.normalizedIPAddress(host) else { return false }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, literal, &ipv4) == 1 {
            let octets = withUnsafeBytes(of: ipv4) { Array($0) }
            switch (octets[0], octets[1]) {
            case (10, _), (172, 16...31), (192, 168), (169, 254):
                return true
            default:
                return false
            }
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        return bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
    }

    /// The saved settings with the address of `device`. A camera saved with HTTPS
    /// keeps HTTPS and its saved port when the scan reports plain HTTP for it, so its
    /// login never goes unencrypted. What the user decided for the saved address (a
    /// trusted certificate, plain HTTP allowed) is not kept for another one.
    private static func settings(for info: ONVIFSourceInfo, at device: DiscoveredDevice) -> ONVIFSourceInfo {
        var found = info
        found.host = device.host
        if device.useHTTPS || !info.useHTTPS {
            found.port = device.port
            found.useHTTPS = device.useHTTPS
        }
        if !found.hasAddress(of: info) { found.clearAddressDecisions() }
        return found
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
