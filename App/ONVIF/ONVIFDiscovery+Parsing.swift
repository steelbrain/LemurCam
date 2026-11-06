import Darwin
import Foundation
import XMLKit

// Internal (not private) so `@testable` unit tests can exercise reply matching
// without a socket.
internal extension ONVIFDiscovery {
    /// What the receive loop knows about a datagram besides its payload.
    struct ReplyContext {
        /// The `MessageID` the probe was sent with; a ProbeMatch must echo it in `RelatesTo`.
        let probeMessageID: String
        /// Numeric IP address the datagram came from.
        let sender: String
    }

    /// Turns a ProbeMatch reply into a device, or nil when the reply is not a valid
    /// answer to this probe.
    ///
    /// Any host on the LAN can answer the multicast probe. A reply only counts when
    /// its `RelatesTo` echoes this probe's `MessageID`, and the device's address is
    /// always the host the reply came from: the XAddr whose host matches the sender
    /// is preferred, and otherwise the first XAddr is used with its host replaced by
    /// the sender's. A reply therefore cannot point the app (and the credentials it
    /// later sends) at a third host.
    static func parseProbeMatch(xml: String, context: ReplyContext) -> DiscoveredDevice? {
        guard let root = try? ONVIFXML.parse(xml) else { return nil }

        var relatesTo: String?
        root.findElements(named: "RelatesTo") { element in
            if relatesTo == nil { relatesTo = element.getText() }
        }
        guard let relatesTo, sameMessageID(relatesTo, context.probeMessageID) else { return nil }

        var match: XMLKit.XMLElement?
        root.findElements(named: "ProbeMatch") { element in
            if match == nil { match = element }
        }
        guard let match,
              let address = match["EndpointReference"]?["Address"]?.getText(),
              let xaddrs = match["XAddrs"]?.getText(),
              let endpoint = endpoint(fromXAddrs: xaddrs, sender: context.sender) else { return nil }

        let uuid = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "urn:uuid:", with: "")
        guard !uuid.isEmpty else { return nil }

        let scopes = match["Scopes"]?.getText() ?? ""
        return DiscoveredDevice(
            endpointUUID: uuid,
            endpointURL: endpoint.url,
            name: extractScope(from: scopes, key: "name")?.removingPercentEncoding,
            manufacturer: (extractScope(from: scopes, key: "hardware")
                ?? extractScope(from: scopes, key: "manufacturer"))?.removingPercentEncoding,
            model: extractScope(from: scopes, key: "model")?.removingPercentEncoding,
            host: endpoint.host,
            port: endpoint.port
        )
    }

    static func extractScope(from scopes: String, key: String) -> String? {
        let prefix = "onvif://www.onvif.org/\(key)/"
        for scope in scopes.split(whereSeparator: \.isWhitespace) where scope.hasPrefix(prefix) {
            let value = String(scope.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - XAddrs

    /// Picks the device service address from a whitespace-separated XAddrs list (any
    /// whitespace, including newlines, separates entries). See `parseProbeMatch`.
    static func endpoint(fromXAddrs xaddrs: String, sender: String) -> (url: String, host: String, port: Int)? {
        let candidates = xaddrs.split(whereSeparator: \.isWhitespace).compactMap { entry -> URLComponents? in
            guard let components = URLComponents(string: String(entry)),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty else { return nil }
            return components
        }
        guard let senderIP = normalizedIPAddress(sender) else { return nil }
        let matching = candidates.first { $0.host.flatMap(normalizedIPAddress) == senderIP }
        guard var components = matching ?? candidates.first else { return nil }

        let host = senderIP.contains(":") ? "[\(senderIP)]" : senderIP
        components.percentEncodedHost = host
        let isHTTPS = components.scheme?.lowercased() == "https"
        let port = components.port ?? (isHTTPS ? Tuning.defaultHTTPSPort : Tuning.defaultHTTPPort)
        guard let url = components.string else { return nil }
        return (url, host, port)
    }

    /// Canonical text form of an IP literal, so `192.168.1.5`, `::ffff:192.168.1.5`
    /// and `[::FFFF:192.168.1.5]` compare equal. IPv6 zone identifiers are ignored.
    /// Nil for anything that is not an IP literal, such as a host name.
    static func normalizedIPAddress(_ host: String) -> String? {
        var literal = host
        if literal.hasPrefix("["), literal.hasSuffix("]") {
            literal = String(literal.dropFirst().dropLast())
        }
        if let zone = literal.firstIndex(of: "%") {
            literal = String(literal[..<zone])
        }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, literal, &ipv4) == 1 {
            return format(ipv4)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, literal, &ipv6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return bytes[12..<16].map(String.init).joined(separator: ".")
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    static func format(_ address: in_addr) -> String? {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// `RelatesTo` must echo the probe's `MessageID`. Compared case-insensitively and
    /// ignoring a `urn:` prefix, since devices differ in how they spell the UUID URI.
    static func sameMessageID(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.hasPrefix("urn:") { text.removeFirst(4) }
            return text
        }
        let left = canonical(lhs)
        return !left.isEmpty && left == canonical(rhs)
    }
}
