@testable import LemurCam
import XCTest

internal final class ONVIFReconnectTests: XCTestCase {

    // MARK: - attemptONVIFResolve

    func testAttemptResolveReturnsNilForUnreachableHost() async throws {
        let info = ONVIFSourceInfo(host: "127.0.0.1", port: 1)
        let params = ONVIFResolveParams(
            info: info, token: "profile_1",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let result = try await StreamCoordinator.attemptONVIFResolve(params: params)
        XCTAssertNil(try? result.get())
    }

    func testAttemptResolveSkipsDiscoveryWhenNoUUID() async throws {
        let info = ONVIFSourceInfo(deviceUUID: nil, host: "127.0.0.1", port: 1)
        let params = ONVIFResolveParams(
            info: info, token: "tok",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let result = try await StreamCoordinator.attemptONVIFResolve(params: params)
        XCTAssertNil(try? result.get())
    }

    func testAttemptResolveSkipsDiscoveryWhenUUIDEmpty() async throws {
        let info = ONVIFSourceInfo(deviceUUID: "", host: "127.0.0.1", port: 1)
        let params = ONVIFResolveParams(
            info: info, token: "tok",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let result = try await StreamCoordinator.attemptONVIFResolve(params: params)
        XCTAssertNil(try? result.get())
    }

    // MARK: - resolveONVIFStreamURI (timeout)

    /// The camera takes the connection and never answers. This used to target
    /// 192.0.2.1, which App Transport Security now refuses at once, so the test passed
    /// without the timeout ever firing. A loopback listener keeps it on this machine.
    func testResolveTimesOutWhenTheCameraNeverAnswers() async throws {
        let listener = try SilentLoopbackListener()
        defer { listener.close() }
        let info = ONVIFSourceInfo(host: "127.0.0.1", port: listener.port)
        let params = ONVIFResolveParams(
            info: info, token: "tok",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let timeout: TimeInterval = 0.5
        let start = Date()
        let result = await StreamCoordinator.resolveONVIFStreamURI(params: params, timeout: timeout)
        let elapsed = Date().timeIntervalSince(start)

        guard case .failure(let error) = result, case .timedOut? = error as? ONVIFError else {
            XCTFail("expected ONVIFError.timedOut, got \(result)")
            return
        }
        XCTAssertGreaterThanOrEqual(elapsed, timeout * 0.9, "the timeout, not a failed request, must end it")
        // The request timeout is 10 s: well under it means the hung request was cancelled.
        XCTAssertLessThan(elapsed, 3.0)
    }

    func testResolveReturnsNilForUnreachableWithoutTimeout() async {
        let info = ONVIFSourceInfo(host: "127.0.0.1", port: 1)
        let params = ONVIFResolveParams(
            info: info, token: "tok",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let start = Date()
        let result = await StreamCoordinator.resolveONVIFStreamURI(params: params, timeout: 10.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(try? result.get())
        XCTAssertLessThan(elapsed, 5.0)
    }
}

/// A TCP listener on 127.0.0.1 that never answers. The kernel completes incoming
/// connections in the listen backlog, so a client connects and sends its request,
/// and then waits for a reply that never comes. Nothing leaves this machine.
private final class SilentLoopbackListener {
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
