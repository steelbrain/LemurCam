import Foundation
@testable import LemurCam
import os
import Security
import XCTest

/// A self-signed certificate, as a camera ships with, for exercising the TLS trust
/// decision without a server: an EC P-256 certificate for `camera.test`, made with
/// `openssl req -x509` and valid from 2026-11-06 to 2029-01-14. No key is kept.
internal enum TestCertificate {
    static let der = Data(base64Encoded: """
        MIIBnTCCAUOgAwIBAgIUBgpDXBSd8pWeCnCZFA8IRaqmZ7cwCgYIKoZIzj0EAwIwFjEUMBIGA1UEAwwLY2FtZXJhLnRlc3QwHhcNMjYx\
        MTA2MTcyNTI2WhcNMjkwMTE0MTcyNTI2WjAWMRQwEgYDVQQDDAtjYW1lcmEudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOHq\
        iqsRpz3S6xKf7+g17wSO3wkpwUwJm2Ig3WGIJ0o3gDd9faKB/ST+pvo7ZvgV9cAiA2mil0219vAxUuGDDF+jbzBtMB0GA1UdDgQWBBQb\
        rOhufygkuxQPhlEPeLywWzWC+DAPBgNVHRMBAf8EBTADAQH/MBYGA1UdEQQPMA2CC2NhbWVyYS50ZXN0MBMGA1UdJQQMMAoGCCsGAQUF\
        BwMBMA4GA1UdDwEB/wQEAwIHgDAKBggqhkjOPQQDAgNIADBFAiEAqcNuzwQm3WDwRC2THs9y28LXuib3xsg0i5fx3CIiHRUCIAU6e6uD\
        T6NYL1psdVDLSxF1nHe86bjzIzaJCxnLCJFH
        """) ?? Data()

    /// What `openssl x509 -noout -fingerprint -sha256` prints for it, after `=`.
    static let opensslFingerprint =
        "B2:25:B9:BB:A1:53:3B:D2:10:97:BC:89:CA:AB:32:96:41:C7:56:5B:A8:FA:63:BD:CB:38:70:E1:FD:88:18:CE"

    /// Another certificate's fingerprint: what a camera presenting this one doesn't match.
    static let otherFingerprint = CertificateFingerprint(certificateData: Data("another certificate".utf8))

    static func certificate() throws -> SecCertificate {
        try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
    }

    /// The trust a TLS connection to `host` presenting the certificate gets. When
    /// `anchored`, the certificate is its trust anchor, standing in for one macOS
    /// trusts; the check is pinned to a date the certificate is valid on.
    static func serverTrust(host: String = "camera.test", anchored: Bool = false) throws -> SecTrust {
        let certificate = try certificate()
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
        XCTAssertEqual(status, errSecSuccess)
        let created = try XCTUnwrap(trust)
        SecTrustSetNetworkFetchAllowed(created, false)
        if anchored {
            SecTrustSetAnchorCertificates(created, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(created, true)
            // 2027-01-15, within the certificate's validity.
            SecTrustSetVerifyDate(created, Date(timeIntervalSince1970: 1_800_000_000) as CFDate)
        }
        return created
    }

    /// The server-trust challenge a TLS connection presenting `trust` raises.
    static func challenge(_ trust: SecTrust) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: ServerTrustSpace(trust: trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: IgnoredChallengeSender()
        )
    }

    /// `ONVIFServerTrust.decision(for:pin:)` for a connection to `host` presenting
    /// the certificate (see `serverTrust(host:anchored:)`).
    static func decision(
        pin: CertificateFingerprint?, host: String = "camera.test", anchored: Bool = false
    ) throws -> ONVIFServerTrust.Decision {
        let shared = SendableTrust(trust: try serverTrust(host: host, anchored: anchored))
        return try XCTUnwrap(offMainThread { ONVIFServerTrust.decision(for: shared.trust, pin: pin) })
    }

    /// Has `delegate` meet the certificate, as a connection to the camera would, and
    /// returns how it answered. A stub `URLProtocol` can't present one: the session
    /// hands its delegate a copy of the protection space without the trust.
    @discardableResult
    static func present(
        _ trust: SecTrust, to delegate: ONVIFServerTrustDelegate
    ) -> URLSession.AuthChallengeDisposition? {
        let shared = SendableTrust(trust: trust)
        return offMainThread {
            let answer = OSAllocatedUnfairLock<URLSession.AuthChallengeDisposition?>(initialState: nil)
            delegate.urlSession(URLSession.shared, didReceive: challenge(shared.trust)) { disposition, _ in
                answer.withLock { $0 = disposition }
            }
            return answer.withLock { $0 }
        }
    }

    /// Runs `work` on a thread of its own and waits for it. macOS warns when a trust is
    /// evaluated on the main thread, where tests run; the session's delegate queue,
    /// where the app evaluates them, never is.
    private static func offMainThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value?) -> Value? {
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let value = work()
            result.withLock { $0 = value }
            done.signal()
        }
        thread.start()
        done.wait()
        return result.withLock { $0 }
    }
}

/// A `SecTrust` handed to another thread. It is only read.
internal struct SendableTrust: @unchecked Sendable {
    let trust: SecTrust
}

/// A protection space that carries `trust`, as one for a TLS connection does.
private final class ServerTrustSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(trust: SecTrust) {
        self.trust = trust
        super.init(
            host: "camera.test", port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var serverTrust: SecTrust? { trust }
}

private final class IgnoredChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
}
