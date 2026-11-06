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
    /// no answer in time (IPCamKit's `RTSPError.timeout`, or the app's own
    /// `TimeoutError`). A camera that answered with an error (authentication, a 404,
    /// a TLS handshake) was reached, and so was one that closed or reset the
    /// connection after it was made (`Connection reset by peer`, from the system's
    /// untranslated error text). A URL IPCamKit refused before connecting tells
    /// nothing either.
    static func isHostUnreachable(_ error: any Error) -> Bool {
        if error is TimeoutError { return true }
        guard let rtspError = error as? RTSPError else { return false }
        switch rtspError {
        case .timeout:
            return true
        case .connectionFailed(let message):
            return !notAboutReachingTheHost.contains { message.hasPrefix($0) }
                && !message.contains("Connection reset by peer")
        default:
            return false
        }
    }

    /// How IPCamKit starts a `connectionFailed` message that isn't about making the
    /// connection: a URL it refused (`Invalid URL…`, `Invalid port…`), a TLS handshake
    /// the camera answered, or reading from or writing to a connection that was made.
    /// Any other message is the Network framework's reason the connection failed.
    private static let notAboutReachingTheHost = [
        "Invalid", "TLS ", "Read error", "Send failed", "Not connected", "control send failed"
    ]
}

extension SourceManager {
    /// Shows why an ONVIF camera's stream URI could not be resolved, noting whether
    /// the camera gave no answer at all (`ONVIFError.isTransportFailure`).
    func updateErrorMessage(for sourceID: UUID, onvifResolveFailure error: any Error) {
        updateErrorMessage(
            for: sourceID, message: StreamCoordinator.onvifResolveFailureMessage(for: error),
            hostUnreachable: (error as? ONVIFError)?.isTransportFailure == true
        )
    }
}
