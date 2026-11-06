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

        guard case .failure(let failure) = result, case .timedOut? = failure.error as? ONVIFError else {
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
