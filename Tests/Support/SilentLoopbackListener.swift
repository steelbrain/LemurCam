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

    func close() {
        Darwin.close(descriptor)
    }
}
