import Foundation

/// Best-effort guidance for the macOS Local Network privacy gate.
///
/// macOS exposes no API to query Local Network authorization (unlike camera/mic),
/// so this is heuristic: when a stream to a *LAN* camera fails, the most common
/// silent cause is a denied or never-granted Local Network permission. We surface a
/// hint only for LAN hosts — a public/remote camera that is merely offline never
/// triggers it — with a deep link to the settings pane. Kept pure so the host
/// classification and the show/hide gate are unit-testable.
internal enum LocalNetworkGuidance {
    /// Deep link to System Settings → Privacy & Security → Local Network.
    static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

    /// Whether to show the Local Network hint for a source in the given state: only
    /// when its connection has errored and the camera lives on the local network.
    static func isLikelyBlocked(host: String?, status: ConnectionStatus) -> Bool {
        guard status == .error, let host, isLANHost(host) else { return false }
        return true
    }

    /// The host a source connects to (RTSP URL host, or the ONVIF host).
    static func host(for source: CameraSource) -> String? {
        switch source.sourceType {
        case .onvif(let info): return info.host
        case .rtsp(let info): return URL(string: info.url)?.host
        }
    }

    /// Whether a host refers to a device on the local network, so Local Network
    /// permission would gate reaching it: RFC1918 ranges, link-local, loopback, and
    /// mDNS `.local` names. A bare public hostname returns false (its failure isn't
    /// attributable to the Local Network gate).
    static func isLANHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") { return true }
        let parts = lower.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return isPrivateIPv4(octets)
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch octets[0] {
        case 10, 127: return true
        case 169: return octets[1] == 254
        case 172: return (16...31).contains(octets[1])
        case 192: return octets[1] == 168
        default: return false
        }
    }
}
