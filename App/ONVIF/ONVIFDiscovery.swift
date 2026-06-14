import Darwin
import Foundation
import XMLKit

private typealias XElement = XMLKit.XMLElement

/// Sendable: holds no instance stored state (only static config + methods), so
/// instances are trivially safe to pass into tasks.
internal final class ONVIFDiscovery: Sendable {
    private static let multicastAddress = "239.255.255.250"
    private static let multicastPort: UInt16 = 3702
    private static let scanDuration: TimeInterval = 5

    func scan() async -> [DiscoveredDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = Self.performScan()
                continuation.resume(returning: devices)
            }
        }
    }

    // MARK: - BSD Socket Scan

    /// Uses a plain UDP socket to send to the multicast address and receive
    /// unicast replies. This avoids joining the multicast group, which would
    /// trigger the macOS "accept incoming connections" firewall prompt.
    private static func performScan() -> [DiscoveredDevice] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            Log.app.error("WS-Discovery: failed to create socket")
            return []
        }
        defer { close(sock) }

        guard bindSocket(sock) else { return [] }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard sendProbe(sock) else { return [] }

        return collectResponses(sock)
    }

    private static func bindSocket(_ sock: Int32) -> Bool {
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        bindAddr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Log.app.error("WS-Discovery: bind failed (\(errno))")
            return false
        }
        return true
    }

    private static func sendProbe(_ sock: Int32) -> Bool {
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = multicastPort.bigEndian
        inet_pton(AF_INET, multicastAddress, &destAddr.sin_addr)

        let probe = Array(buildProbeMessage().utf8)

        let sent = probe.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &destAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(sock, buf.baseAddress, buf.count, 0,
                           sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else {
            Log.app.error("WS-Discovery: sendto failed (\(errno))")
            return false
        }
        return true
    }

    private static func collectResponses(_ sock: Int32) -> [DiscoveredDevice] {
        var devices: [DiscoveredDevice] = []
        var seenUUIDs: Set<String> = []
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(scanDuration)

        while Date() < deadline {
            var senderAddr = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let received = withUnsafeMutablePointer(to: &senderAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(sock, &buffer, buffer.count, 0, sockPtr, &senderLen)
                }
            }
            let errnoValue = errno

            switch receiveOutcome(received: received, errnoValue: errnoValue) {
            case .process(let count):
                let data = Data(buffer[0..<count])
                if let xml = String(data: data, encoding: .utf8),
                   let device = parseProbeMatch(xml: xml),
                   !seenUUIDs.contains(device.id) {
                    seenUUIDs.insert(device.id)
                    devices.append(device)
                }
            case .retry:
                continue
            case .backOff:
                Log.app.error("WS-Discovery: recvfrom error (\(errnoValue)), backing off")
                Thread.sleep(forTimeInterval: 0.02)
            case .stop:
                Log.app.error("WS-Discovery: recvfrom socket error (\(errnoValue)), ending scan")
                return devices
            }
        }

        return devices
    }

    // MARK: - WS-Discovery Probe

    private static func buildProbeMessage() -> String {
        let messageID = UUID().uuidString

        var action = XElement.build("Action", attributes: ["s:mustUnderstand": "1"]) {
            "http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe"
        }
        action.prefix = "a"

        var msgID = XElement.build("MessageID") { "uuid:\(messageID)" }
        msgID.prefix = "a"

        var replyAddr = XElement.build("Address") {
            "http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous"
        }
        replyAddr.prefix = "a"
        var replyTo = XElement.build("ReplyTo") { replyAddr }
        replyTo.prefix = "a"

        var to = XElement.build("To", attributes: ["s:mustUnderstand": "1"]) {
            "urn:schemas-xmlsoap-org:ws:2005:04:discovery"
        }
        to.prefix = "a"

        var types = XElement.build("Types") { "dn:NetworkVideoTransmitter" }
        types.prefix = "d"
        var probe = XElement.build("Probe") { types }
        probe.prefix = "d"

        var header = XElement.build("Header") { action; msgID; replyTo; to }
        header.prefix = "s"

        var body = XElement.build("Body") { probe }
        body.prefix = "s"

        var envelope = XElement.build("Envelope") { header; body }
        envelope.prefix = "s"
        envelope.namespaces = XMLNamespaceMap([
            "s": "http://www.w3.org/2003/05/soap-envelope",
            "a": "http://schemas.xmlsoap.org/ws/2004/08/addressing",
            "d": "http://schemas.xmlsoap.org/ws/2005/04/discovery",
            "dn": "http://www.onvif.org/ver10/network/wsdl"
        ])

        return envelope.write()
    }

    // MARK: - Response Parsing

    static func parseProbeMatch(xml: String) -> DiscoveredDevice? {
        guard let root = try? XElement.parse(xml) else { return nil }

        var uuid: String?
        var xaddrs: String?
        var scopes: String?

        root.findElements(named: "EndpointReference") { epRef in
            if let addr = epRef["Address"] {
                uuid = addr.getText()
            }
        }
        root.findElements(named: "XAddrs") { el in
            xaddrs = el.getText()
        }
        root.findElements(named: "Scopes") { el in
            scopes = el.getText()
        }

        guard let uuid, let xaddrs else { return nil }

        // Parse host and port from XAddrs URL
        let endpointURL = xaddrs.components(separatedBy: " ").first ?? xaddrs
        var host = ""
        var port = Tuning.defaultHTTPPort
        if let urlComponents = URLComponents(string: endpointURL) {
            host = urlComponents.host ?? ""
            port = urlComponents.port
                ?? (urlComponents.scheme == "https" ? Tuning.defaultHTTPSPort : Tuning.defaultHTTPPort)
        }
        guard !host.isEmpty else { return nil }

        // Parse scopes for device metadata
        let scopesStr = scopes ?? ""
        let name = extractScope(from: scopesStr, key: "name")
        let manufacturer = extractScope(from: scopesStr, key: "hardware")
            ?? extractScope(from: scopesStr, key: "manufacturer")
        let model = extractScope(from: scopesStr, key: "model")

        // Clean UUID — strip "urn:uuid:" prefix if present
        let cleanUUID = uuid.replacingOccurrences(of: "urn:uuid:", with: "")

        return DiscoveredDevice(
            id: cleanUUID,
            endpointURL: endpointURL,
            name: name?.removingPercentEncoding,
            manufacturer: manufacturer?.removingPercentEncoding,
            model: model?.removingPercentEncoding,
            host: host,
            port: port
        )
    }

    static func extractScope(from scopes: String, key: String) -> String? {
        let prefix = "onvif://www.onvif.org/\(key)/"
        for scope in scopes.components(separatedBy: " ") where scope.hasPrefix(prefix) {
            let value = String(scope.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

}

// MARK: - Receive Error Handling

internal extension ONVIFDiscovery {
    /// What the receive loop should do with a `recvfrom` result. Pulled out as a pure
    /// function so the error handling is unit-testable without a live socket.
    enum ReceiveOutcome: Equatable {
        case process(Int)   // got `n` bytes — parse them
        case retry          // benign (timeout, interrupt, empty datagram) — loop again
        case backOff        // transient hard error — pause briefly so we don't busy-spin
        case stop           // socket is unusable — abandon the scan
    }

    /// Decide how to handle a `recvfrom` return value. `SO_RCVTIMEO` makes a no-data
    /// interval surface as `EAGAIN` *after* blocking, so retrying it doesn't spin. A
    /// hard error (e.g. `ECONNREFUSED` from an ICMP port-unreachable), however, returns
    /// immediately, so retrying it tightly would burn a core for the rest of the scan —
    /// hence `backOff`. `errnoValue` is only consulted when `received < 0`.
    static func receiveOutcome(received: Int, errnoValue: Int32) -> ReceiveOutcome {
        if received > 0 { return .process(received) }
        if received == 0 { return .retry } // zero-length datagram is valid, just empty
        switch errnoValue {
        case EAGAIN, EINTR: // EWOULDBLOCK == EAGAIN on Darwin
            return .retry
        case EBADF, ENOTSOCK:
            return .stop
        default:
            return .backOff
        }
    }
}
