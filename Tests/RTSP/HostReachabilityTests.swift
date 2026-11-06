import IPCamKit
@testable import LemurCam
import XCTest

/// Which stream failures mean the camera's host couldn't be reached at all. Only
/// those show the Local Network hint: it used to show for any error on a LAN camera,
/// including ones that prove the camera answered.
internal final class HostReachabilityTests: XCTestCase {
    /// How the Network framework's reasons read once IPCamKit wraps them.
    private func networkFailure(_ code: Int, _ reason: String) -> RTSPError {
        .connectionFailed("The operation couldn’t be completed. (Network.NWError error \(code) - \(reason))")
    }

    func testNoConnectionToTheHostIsUnreachable() {
        let errors: [any Error] = [
            networkFailure(65, "No route to host"),
            networkFailure(61, "Connection refused"),
            networkFailure(51, "Network is unreachable"),
            networkFailure(-65_554, "NoSuchRecord")
        ]
        for error in errors {
            XCTAssertTrue(RTSPStreamPipeline.isHostUnreachable(error), "\(error)")
        }
    }

    func testACameraThatAnsweredIsNotUnreachable() {
        let errors: [any Error] = [
            RTSPError.authenticationFailed,
            RTSPError.sessionSetupFailed(statusCode: 404, reason: "Not Found"),
            RTSPError.invalidSDP("no media"),
            RTSPError.transportNegotiationFailed,
            RTSPError.unexpectedDisconnection,
            RTSPError.connectionFailed("TLS handshake failed: bad certificate format (OSStatus -9808)"),
            RTSPError.connectionFailed("Read error: The operation couldn’t be completed."),
            RTSPError.connectionFailed("Send failed: The operation couldn’t be completed."),
            networkFailure(54, "Connection reset by peer"),
            RTSPError.connectionFailed("RTSP read buffer exceeded 4194304 bytes without a complete message"),
            RTSPStreamPipeline.NoVideoStreamError(),
            RTSPStreamPipeline.StreamStallError(),
            RTSPStreamPipeline.VideoDecodeStallError(),
            CancellationError()
        ]
        for error in errors {
            XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(error), "\(error)")
        }
    }

    /// IPCamKit's `RTSPError.timeout` is the same for a TCP connect that never
    /// finished and for a camera that accepted the connection but never answered
    /// OPTIONS, DESCRIBE, SETUP or PLAY; the app's `TimeoutError` covers the whole
    /// setup. Both used to count as unreachable, so a wedged camera on the network
    /// showed the Local Network hint. Denied Local Network access, no route and a
    /// refused connection all fail as `connectionFailed` instead.
    func testATimeoutIsNotUnreachable() {
        XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(RTSPError.timeout))
        XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(RTSPStreamPipeline.TimeoutError()))
    }

    /// IPCamKit refuses a URL whose `@` it can't place before connecting anywhere.
    func testARefusedURLIsNotUnreachable() {
        let refused = RTSPError.connectionFailed(
            "Invalid URL (an @ after the host that may end a user name or password; write /, ?, # and "
                + "@ in a user name or password as %2F, %3F, %23 and %40, and an @ in the path as %40): "
                + "rtsp://192.168.1.5:554/live?password=***"
        )
        XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(refused))
        XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(RTSPError.connectionFailed("Invalid port 0 in URL: x")))
    }

    func testOnlyAFailureBeforeTheSessionWasSetUpCanBeUnreachable() {
        let noRoute = networkFailure(65, "No route to host")
        XCTAssertEqual(
            RTSPStreamPipeline.failureState(for: noRoute, afterSetup: false),
            .error(noRoute.localizedDescription, hostUnreachable: true)
        )
        XCTAssertEqual(
            RTSPStreamPipeline.failureState(for: noRoute, afterSetup: true),
            .error(noRoute.localizedDescription, hostUnreachable: false)
        )
        XCTAssertEqual(
            RTSPStreamPipeline.failureState(for: RTSPError.timeout, afterSetup: false),
            .error("Timeout")
        )
        XCTAssertEqual(
            RTSPStreamPipeline.failureState(for: RTSPError.authenticationFailed, afterSetup: false),
            .error("Authentication failed")
        )
    }
}
