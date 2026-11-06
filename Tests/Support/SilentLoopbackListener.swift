import Foundation

/// A TCP listener on 127.0.0.1 that never answers. The kernel completes incoming
/// connections in the listen backlog, so a client connects and sends its request,
/// and then waits for a reply that never comes. Nothing leaves this machine.
internal final class SilentLoopbackListener: Sendable {
    struct SocketError: Error {
        let call: String
        let code: Int32
    }

    /// The port the kernel picked.
    let port: Int
    private let descriptor: Int32

    init() throws {
        let opened = socket(AF_INET, SOCK_STREAM, 0)
        guard opened >= 0 else { throw SocketError(call: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(opened, socketAddress, length) == 0
                    && listen(opened, 8) == 0
                    && getsockname(opened, socketAddress, &length) == 0
            }
        }
        guard listening else {
            let code = errno
            Darwin.close(opened)
            throw SocketError(call: "bind, listen or getsockname", code: code)
        }
        descriptor = opened
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// Takes the next connection, reads the first line the client sends (an RTSP
    /// request line) without answering, and closes that connection. Blocks the calling
    /// thread for up to `timeout` at each wait; nil when no connection or no full line
    /// comes in time.
    func readRequestLine(timeout: TimeInterval = 5) -> String? {
        let milliseconds = Int32(timeout * 1000)
        var listening = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&listening, 1, milliseconds) == 1 else { return nil }
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return nil }
        defer { Darwin.close(client) }
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !received.contains(UInt8(ascii: "\n")) {
            var readable = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, milliseconds) == 1 else { return nil }
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            received += buffer[..<count]
        }
        let line = received.prefix { $0 != UInt8(ascii: "\r") && $0 != UInt8(ascii: "\n") }
        return String(bytes: line, encoding: .utf8)
    }

    func close() {
        Darwin.close(descriptor)
    }
}
