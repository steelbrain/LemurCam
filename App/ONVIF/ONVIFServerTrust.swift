import Foundation
import os
import Security

/// What an `ONVIFClient` accepts on the way to its camera beyond what macOS allows on
/// its own. Both are the user's decisions about one camera at one address, saved with
/// it (`ONVIFSourceInfo.connectionPolicy`), and neither follows the camera to another
/// address (`ONVIFSourceInfo.clearAddressDecisions()`).
internal struct ONVIFConnectionPolicy: Equatable, Sendable {
    /// The certificate the user trusted for this camera (trust on first use). It is
    /// accepted when macOS doesn't trust it, as long as the camera presents exactly it.
    var pinnedCertificate: CertificateFingerprint?
    /// Whether the user allowed plain HTTP to this camera although its address is
    /// outside the local network (`ONVIFLocalNetwork`).
    var allowsPlainHTTPOutsideLocalNetwork = false
}

/// A camera's TLS certificate that an `ONVIFClient` refused.
internal struct ONVIFCertificateProblem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// macOS doesn't trust it, and the user has trusted no certificate for the camera.
        case untrusted
        /// macOS doesn't trust it, and it is not the certificate the user trusted.
        case changed
    }

    let kind: Kind
    /// The camera's host, as saved.
    let host: String
    /// The certificate the camera presented.
    let fingerprint: CertificateFingerprint

    /// What the camera list shows. Only the edit form can trust the certificate: it
    /// asks once Fetch Profiles meets it.
    var statusMessage: String {
        let what = kind == .changed ? "changed" : "isn't trusted"
        return "The certificate of the camera at \(host) \(what). "
            + "Open the camera in Settings and click Fetch Profiles to review it."
    }
}

/// How an `ONVIFClient` answers a camera's TLS certificate. A camera's own certificate
/// is self-signed, so macOS never trusts it, and Use HTTPS failed every request with a
/// TLS error. A certificate macOS trusts is accepted as before. Otherwise one whose
/// SHA-256 fingerprint is the pinned one is accepted: the same certificate, so its
/// host names and expiry date don't matter. Any other is refused, and the request
/// fails with the certificate's fingerprint, for the user to trust or not.
internal enum ONVIFServerTrust {
    enum Decision: Equatable {
        case trustedBySystem
        case matchesPin
        /// `fingerprint` is nil when the camera presented no certificate at all.
        case refused(ONVIFCertificateProblem.Kind, fingerprint: CertificateFingerprint?)
    }

    static func decision(
        systemTrusted: Bool, leaf: CertificateFingerprint?, pin: CertificateFingerprint?
    ) -> Decision {
        if systemTrusted { return .trustedBySystem }
        if let leaf, leaf == pin { return .matchesPin }
        return .refused(pin == nil ? .untrusted : .changed, fingerprint: leaf)
    }

    /// Evaluates `trust` with its own policy (TLS for the requested host), then
    /// decides on its leaf certificate.
    static func decision(for trust: SecTrust, pin: CertificateFingerprint?) -> Decision {
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
        let leaf = chain?.first.map(CertificateFingerprint.init(certificate:))
        return decision(systemTrusted: systemTrusted, leaf: leaf, pin: pin)
    }
}

/// An `ONVIFClient`'s `URLSession` delegate: answers each server-trust challenge as
/// `ONVIFServerTrust` decides, and keeps the certificate it last refused, which the
/// failed request reports (`ONVIFError.certificateNotTrusted`). A refused challenge
/// is cancelled, so no request body, and with it no WS-Security header, is sent.
internal final class ONVIFServerTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    private let host: String
    private let pin: CertificateFingerprint?
    private let refused = OSAllocatedUnfairLock<ONVIFCertificateProblem?>(initialState: nil)

    init(host: String, pin: CertificateFingerprint?) {
        self.host = host
        self.pin = pin
    }

    /// The certificate the camera presented that was last refused, if any was.
    var lastRefusal: ONVIFCertificateProblem? {
        refused.withLock { $0 }
    }

    func urlSession(
        _: URLSession, didReceive challenge: URLAuthenticationChallenge,
        // Called before this returns, but the protocol declares the handler escaping.
        // swiftlint:disable:next unneeded_escaping
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch ONVIFServerTrust.decision(for: trust, pin: pin) {
        case .trustedBySystem:
            completionHandler(.performDefaultHandling, nil)
        case .matchesPin:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case let .refused(kind, fingerprint):
            if let fingerprint {
                let problem = ONVIFCertificateProblem(kind: kind, host: host, fingerprint: fingerprint)
                refused.withLock { $0 = problem }
            }
            Log.app.info("Refused the certificate of the ONVIF camera at \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
