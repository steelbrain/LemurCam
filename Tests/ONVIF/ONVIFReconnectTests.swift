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
        XCTAssertNil(result)
    }

    func testAttemptResolveSkipsDiscoveryWhenNoUUID() async throws {
        let info = ONVIFSourceInfo(deviceUUID: nil, host: "127.0.0.1", port: 1)
        let params = ONVIFResolveParams(
            info: info, token: "tok",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let result = try await StreamCoordinator.attemptONVIFResolve(params: params)
        XCTAssertNil(result)
    }

    func testAttemptResolveSkipsDiscoveryWhenUUIDEmpty() async throws {
        let info = ONVIFSourceInfo(deviceUUID: "", host: "127.0.0.1", port: 1)
        let params = ONVIFResolveParams(
            info: info, token: "tok",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let result = try await StreamCoordinator.attemptONVIFResolve(params: params)
        XCTAssertNil(result)
    }

    // MARK: - resolveONVIFStreamURI (timeout)

    func testResolveTimesOutAndReturnsNil() async {
        let info = ONVIFSourceInfo(host: "192.0.2.1", port: 80)
        let params = ONVIFResolveParams(
            info: info, token: "tok",
            credentials: nil, sourceID: UUID(),
            sourceName: "Test", sourceManager: nil
        )
        let start = Date()
        let result = await StreamCoordinator.resolveONVIFStreamURI(params: params, timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
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

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 5.0)
    }
}
