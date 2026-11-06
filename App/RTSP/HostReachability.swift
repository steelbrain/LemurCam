import Foundation
import IPCamKit
import Network

// MARK: - Unreachable Host

extension RTSPStreamPipeline {
    /// How a stream that failed with `error` reports it. Only a failure while the
    /// session was being set up (`afterSetup` false) can be the host being out of
    /// reach: once the camera described its streams it was reached, so a stall, a
    /// dropped connection or a stream with no video never counts.
    static func failureState(for error: any Error, afterSetup: Bool) -> State {
        .error(error.localizedDescription, hostUnreachable: !afterSetup && isHostUnreachable(error))
    }

    /// Whether `error`, thrown while setting up a session, means no connection to the
    /// camera's host could be made: refused, no route, a name that didn't resolve, or
    /// Local Network access denied. IPCamKit reports each as `connectionFailed`, once
    /// the connection fails or has been waiting for 2 seconds, with the Network
    /// framework's error as its `underlying` cause: a DNS error, or one of the POSIX
    /// errors in `noConnectionErrors`. The cause decides, not the message's wording.
    ///
    /// A camera that answered was reached: with an error (authentication, a 404), with
    /// a TLS handshake (`.tls`), or by resetting or closing a connection that was made
    /// (`ECONNRESET`, `EPIPE`, `ECONNABORTED`). So was one that sent more than IPCamKit
    /// buffers without completing a message, which has no network cause. A URL
    /// IPCamKit refused before connecting (`invalidURL`) tells nothing either.
    ///
    /// A timeout never counts. IPCamKit's `RTSPError.timeout` is the same for a TCP
    /// connect that never finished and for a camera that accepted the connection but
    /// never answered OPTIONS, DESCRIBE, SETUP or PLAY, and the app's own
    /// `TimeoutError` covers all of `start()`, so neither shows the host was out of
    /// reach. A wedged camera on the network would otherwise be shown as one that
    /// LemurCam may need Local Network access to reach.
    static func isHostUnreachable(_ error: any Error) -> Bool {
        guard case .connectionFailed(_, let underlying)? = error as? RTSPError, let underlying else { return false }
        switch underlying {
        case .dns:
            return true
        case .posix(let code):
            return noConnectionErrors.contains(code)
        default:
            return false
        }
    }

    /// The POSIX errors with which the system reports that a connection to a host
    /// could not be made: refused, no route to the host or its network, the host or
    /// the network down, no answer, no usable local address, or not allowed. On a
    /// connection that was made, they mean the host went out of reach while the
    /// session was being set up.
    private static let noConnectionErrors: Set<POSIXErrorCode> = [
        .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN, .ETIMEDOUT, .EADDRNOTAVAIL,
        .EPERM, .EACCES
    ]
}

extension SourceManager {
    /// Shows why an ONVIF camera's stream URI could not be resolved, noting whether
    /// no connection to its host could be made (`ONVIFError.isHostUnreachable`). Any
    /// failure with no answer used to count, so a camera whose HTTP service hung, or
    /// whose certificate wasn't trusted, showed the Local Network hint.
    func updateErrorMessage(for sourceID: UUID, onvifResolveFailure error: any Error) {
        updateErrorMessage(
            for: sourceID, message: StreamCoordinator.onvifResolveFailureMessage(for: error),
            hostUnreachable: (error as? ONVIFError)?.isHostUnreachable == true
        )
    }
}
