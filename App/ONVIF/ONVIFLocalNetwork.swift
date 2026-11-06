/// Which camera addresses `ONVIFClient` reaches over plain HTTP without the user's
/// allowance for the camera (`ONVIFConnectionPolicy.allowsPlainHTTPOutsideLocalNetwork`).
///
/// The line is where App Transport Security drew it when the app set no ATS keys, as
/// measured on macOS through a loopback proxy. Plain HTTP was allowed to private IPv4
/// (10/8, 172.16/12, 192.168/16), loopback (127/8, ::1), IPv6 link-local (fe80::/10),
/// names without a dot (`camera`), `.local` names and `localhost`. It was blocked
/// (error -1022) to any other IPv4 address (8.8.4.4), global IPv6 (2001:db8::) and
/// fully qualified names (`camera.example.com`, a DDNS name). The app now sets
/// `NSAllowsArbitraryLoads`, so a camera there can be reached once the user allows
/// it, and this check keeps the line for every other camera.
///
/// Not measured, and decided here: IPv4 link-local (169.254/16) is local, like
/// fe80::/10, since it never leaves the link; so are IPv6 unique local addresses
/// (fc00::/7, in use as fd00::/8), which RFC 4193 keeps off the internet. Carrier-grade
/// NAT (100.64/10) is not: it is the ISP's shared address space, so traffic to it
/// crosses the carrier's network. A VPN that hands out such addresses (Tailscale)
/// encrypts on its own, but the app can't tell, so such a camera needs the allowance.
/// These are the ranges `ONVIFRediscovery.isLANAddress` already counts as the LAN, plus
/// loopback.
internal enum ONVIFLocalNetwork {
    /// The name of the per-camera checkbox that allows plain HTTP outside the local
    /// network, as the forms show it and the refusal names it.
    static let allowanceName = "Allow Unencrypted HTTP"

    /// Whether `host` (an IP literal, bracketed or not, or a name) is on the local
    /// network as defined above.
    static func contains(_ host: String) -> Bool {
        if let literal = ONVIFDiscovery.normalizedIPAddress(host) {
            return ONVIFRediscovery.isLANAddress(literal) || literal == "::1" || literal.hasPrefix("127.")
        }
        let name = host.lowercased()
        return name == "localhost" || !name.contains(".") || name.hasSuffix(".local") || name.hasSuffix(".local.")
    }

    /// Whether ONVIF requests to `host` need the user's allowance: they would go over
    /// plain HTTP to an address outside the local network.
    static func needsPlainHTTPAllowance(host: String, useHTTPS: Bool) -> Bool {
        !useHTTPS && !contains(host)
    }
}
