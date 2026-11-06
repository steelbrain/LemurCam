import dnssd
import IPCamKit
@testable import LemurCam
import Network
import Security
import XCTest

/// Which stream failures mean the camera's host couldn't be reached at all. Only
/// those show the Local Network hint: it used to show for any error on a LAN camera,
/// including ones that prove the camera answered.
internal final class HostReachabilityTests: XCTestCase {
    /// A connection IPCamKit couldn't open or keep, as it reports one: the Network
    /// framework's reason as the message, and its error as the cause.
    private func networkFailure(_ error: NWError) -> RTSPError {
        .connectionFailed(error.localizedDescription, underlying: error)
    }

    func testNoConnectionToTheHostIsUnreachable() {
        let errors: [any Error] = [
            networkFailure(.posix(.EHOSTUNREACH)),
            networkFailure(.posix(.ECONNREFUSED)),
            networkFailure(.posix(.ENETUNREACH)),
            networkFailure(.posix(.EHOSTDOWN)),
            networkFailure(.posix(.ENETDOWN)),
            networkFailure(.posix(.ETIMEDOUT)),
            networkFailure(.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord))),
            // What a connection waits with while Local Network access is denied.
            networkFailure(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
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
            RTSPError.connectionFailed(
                "TLS handshake failed: bad certificate format (OSStatus -9808)", underlying: .tls(errSSLBadCert)
            ),
            RTSPError.connectionFailed(
                "Read error: \(NWError.posix(.ECONNRESET).localizedDescription)", underlying: .posix(.ECONNRESET)
            ),
            RTSPError.connectionFailed(
                "Send failed: \(NWError.posix(.EPIPE).localizedDescription)", underlying: .posix(.EPIPE)
            ),
            networkFailure(.posix(.ECONNRESET)),
            RTSPError.connectionFailed("RTSP read buffer exceeded 4194304 bytes without a complete message"),
            RTSPError.connectionFailed("Not connected"),
            RTSPStreamPipeline.NoVideoStreamError(),
            RTSPStreamPipeline.StreamStallError(),
            RTSPStreamPipeline.VideoDecodeStallError(),
            CancellationError()
        ]
        for error in errors {
            XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(error), "\(error)")
        }
    }

    /// The cause decides, not the message's wording. A connection the camera aborted
    /// or that broke once it was made (`ECONNABORTED`, `ENOTCONN`, `EPIPE`) is
    /// reported after the connection was ready with the system's text alone, which no
    /// prefix told from a connection that couldn't be made: it counted as unreachable,
    /// and a camera that answered showed the Local Network hint. So did a failure of
    /// this Mac's own (`ENOBUFS`).
    func testTheCauseDecidesNotTheMessage() {
        for code in [POSIXErrorCode.ECONNABORTED, .ENOTCONN, .EPIPE, .ENOBUFS] {
            XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(networkFailure(.posix(code))), "\(code)")
        }
        // A read that failed because the host went out of reach counts as the
        // connect that fails with the same cause does.
        let noRouteWhileReading = RTSPError.connectionFailed(
            "Read error: \(NWError.posix(.EHOSTUNREACH).localizedDescription)", underlying: .posix(.EHOSTUNREACH)
        )
        XCTAssertTrue(RTSPStreamPipeline.isHostUnreachable(noRouteWhileReading))
        // A message that reads like a network failure, with no network cause behind
        // it, doesn't count.
        let noCause = RTSPError.connectionFailed(NWError.posix(.EHOSTUNREACH).localizedDescription)
        XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(noCause))
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

    /// IPCamKit refuses a URL it can't use before connecting anywhere, as
    /// `invalidURL`, which says nothing about the host.
    func testARefusedURLIsNotUnreachable() {
        let refused = RTSPError.invalidURL(
            "Invalid URL (an @ after the host that may end a user name or password; write /, ?, # and "
                + "@ in a user name or password as %2F, %3F, %23 and %40, and an @ in the path as %40): "
                + "rtsp://cam.local:554/live?password=***"
        )
        XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(refused))
        XCTAssertFalse(RTSPStreamPipeline.isHostUnreachable(RTSPError.invalidURL("Invalid port 0 in URL: x")))
    }

    /// A refused URL is shown with IPCamKit's message alone: it isn't a failed
    /// connection, so it no longer reads "Connection failed: Invalid URL …".
    func testARefusedURLIsShownAsWhatIsWrongWithIt() {
        let message = "Invalid URL (expected rtsp:// or rtsps://): http://192.0.2.5/stream"
        XCTAssertEqual(
            RTSPStreamPipeline.failureState(for: RTSPError.invalidURL(message), afterSetup: false),
            .error(message, hostUnreachable: false)
        )
    }

    func testOnlyAFailureBeforeTheSessionWasSetUpCanBeUnreachable() {
        let noRoute = networkFailure(.posix(.EHOSTUNREACH))
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
