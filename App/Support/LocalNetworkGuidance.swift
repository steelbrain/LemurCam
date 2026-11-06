import Foundation

/// Best-effort guidance for the macOS Local Network privacy gate.
///
/// macOS exposes no API to query Local Network authorization (unlike camera/mic),
/// so this is heuristic: when a connection to a *LAN* camera can't reach its host at
/// all, the most common silent cause is a denied or never-granted Local Network
/// permission. We surface a hint only for LAN hosts — a public/remote camera that is
/// merely offline never triggers it — and only when nothing came back from the host,
/// since a camera that answered (with an authentication failure, a 404, a stream it
/// can't play) was reached through the gate. Kept pure so the host classification and
/// the show/hide gate are unit-testable.
internal enum LocalNetworkGuidance {
    /// Deep link to System Settings → Privacy & Security → Local Network.
    static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

    /// Whether to show the Local Network hint for a source in the given state: only
    /// when its connection failed without reaching the host (`hostUnreachable`, see
    /// `SourceManager.unreachableSourceIDs`) and the camera lives on the local network.
    /// A failed connection schedules its reconnect at once, which shows `.reconnecting`
    /// in the same main-actor turn as `.error`; the failure is kept until the next
    /// attempt starts connecting.
    static func isLikelyBlocked(host: String?, status: ConnectionStatus, hostUnreachable: Bool) -> Bool {
        guard hostUnreachable, status == .error || status == .reconnecting,
              let host, isLANHost(host) else { return false }
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
    /// permission would gate reaching it: IPv4 private (RFC 1918) and link-local
    /// ranges, IPv6 unique local (fc00::/7) and link-local (fe80::/10) addresses, and
    /// `.local` (mDNS) and `.home.arpa` names. Loopback is not gated, so `localhost`
    /// and 127.0.0.0/8 return false, as does a public address or hostname, whose
    /// failure isn't attributable to the Local Network gate.
    static func isLANHost(_ host: String) -> Bool {
        var lower = host.lowercased()
        if lower.hasPrefix("["), lower.hasSuffix("]") {
            lower = String(lower.dropFirst().dropLast())
        }
        if lower.hasSuffix(".") { lower.removeLast() }
        if lower.hasSuffix(".local") || lower.hasSuffix(".home.arpa") { return true }
        if lower.contains(":") { return isLANIPv6(lower) }
        let parts = lower.split(separator: ".")
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return isPrivateIPv4(octets)
    }

    /// `octets`: the four parts of an IPv4 address.
    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch octets[0] {
        case 10: return true
        case 169: return octets[1] == 254
        case 172: return (16...31).contains(octets[1])
        case 192: return octets[1] == 168
        default: return false
        }
    }

    /// Whether an IPv6 address, written without brackets, is unique local or link-local.
    /// A zone (`fe80::1%en0`) is ignored, and an IPv4-mapped address
    /// (`::ffff:192.168.1.5`) is judged by its IPv4 part.
    private static func isLANIPv6(_ address: String) -> Bool {
        let withoutZone = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var bytes = in6_addr()
        guard inet_pton(AF_INET6, withoutZone, &bytes) == 1 else { return false }
        let value = withUnsafeBytes(of: bytes) { Array($0) }
        if value[0..<10].allSatisfy({ $0 == 0 }), value[10] == 0xFF, value[11] == 0xFF {
            return isPrivateIPv4(value[12..<16].map(Int.init))
        }
        let uniqueLocal = value[0] & 0xFE == 0xFC
        let linkLocal = value[0] == 0xFE && value[1] & 0xC0 == 0x80
        return uniqueLocal || linkLocal
    }
}
