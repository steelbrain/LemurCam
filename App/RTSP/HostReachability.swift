import Foundation
import IPCamKit

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
    /// Local Network access denied. IPCamKit reports each as `connectionFailed` with
    /// the Network framework's reason, once the connection fails or has been waiting
    /// for 2 seconds. A camera that answered with an error (authentication, a 404, a
    /// TLS handshake) was reached, and so was one that closed or reset the connection
    /// after it was made (`Connection reset by peer`, from the system's untranslated
    /// error text). A URL IPCamKit refused before connecting tells nothing either.
    ///
    /// A timeout never counts. IPCamKit's `RTSPError.timeout` is the same for a TCP
    /// connect that never finished and for a camera that accepted the connection but
    /// never answered OPTIONS, DESCRIBE, SETUP or PLAY, and the app's own
    /// `TimeoutError` covers all of `start()`, so neither shows the host was out of
    /// reach. A wedged camera on the network would otherwise be shown as one that
    /// LemurCam may need Local Network access to reach.
    static func isHostUnreachable(_ error: any Error) -> Bool {
        guard case .connectionFailed(let message)? = error as? RTSPError else { return false }
        return !notAboutReachingTheHost.contains { message.hasPrefix($0) }
            && !message.contains("Connection reset by peer")
    }

    /// How IPCamKit starts a `connectionFailed` message that isn't about making the
    /// connection: a URL it refused (`Invalid URL…`, `Invalid port…`), a TLS handshake
    /// the camera answered, reading from or writing to a connection that was made, or
    /// a camera that sent more than IPCamKit buffers without completing a message
    /// (`RTSP read buffer exceeded…`). Any other message is the Network framework's
    /// reason the connection failed.
    private static let notAboutReachingTheHost = [
        "Invalid", "TLS ", "Read error", "Send failed", "Not connected", "control send failed", "RTSP read buffer"
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
