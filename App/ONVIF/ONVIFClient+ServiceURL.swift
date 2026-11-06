import Foundation

internal extension ONVIFClient {
    /// The URL of the service at `path` on the camera at `host` and `port`, with the
    /// host written as a URL needs it (`urlHost`). Nil when no URL can hold the host.
    static func serviceURL(host: String, port: Int, useHTTPS: Bool, path: String) -> URL? {
        URL(string: "\(useHTTPS ? "https" : "http")://\(urlHost(host)):\(port)\(path)")
    }

    /// `host` as a URL writes it. An IPv6 address (it has more than one `:`) goes in
    /// brackets, with the `%` before its zone written `%25` (RFC 6874): the address
    /// typed as `fe80::1` or `fe80::1%en0` made
    /// `http://fe80::1%en0:80/onvif/device_service`, which is no URL, so Fetch Profiles
    /// always failed. A zone already written `%25` (`fe80::1%25en0`, as copied from a
    /// URL) is kept. Any other host is returned as it is: one ending in a port
    /// (`192.168.1.64:8080`, which `ONVIFHostInput` refuses) still makes no URL.
    static func urlHost(_ host: String) -> String {
        var address = Substring(host)
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = address.dropFirst().dropLast()
        }
        guard address.firstIndex(of: ":") != address.lastIndex(of: ":") else { return host }
        guard let percent = address.firstIndex(of: "%") else { return "[\(address)]" }
        let zone = address[address.index(after: percent)...]
        let encodedZone = zone.hasPrefix("25") && zone.count > 2 ? zone : "25\(zone)"
        return "[\(address[..<percent])%\(encodedZone)]"
    }
}
