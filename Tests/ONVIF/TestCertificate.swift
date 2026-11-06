import Foundation
@testable import LemurCam
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

    /// Has `client`'s delegate meet the certificate, as a connection to the camera
    /// would, and returns how it answered. A stub `URLProtocol` can't present one:
    /// the session hands its delegate a copy of the protection space without the trust.
    @discardableResult
    static func present(
        _ trust: SecTrust, to delegate: ONVIFServerTrustDelegate
    ) -> URLSession.AuthChallengeDisposition {
        let answer = DispositionBox()
        delegate.urlSession(URLSession.shared, didReceive: challenge(trust)) { disposition, _ in
            answer.set(disposition)
        }
        return answer.value
    }
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

private final class DispositionBox: @unchecked Sendable {
    private(set) var value = URLSession.AuthChallengeDisposition.rejectProtectionSpace

    func set(_ disposition: URLSession.AuthChallengeDisposition) {
        value = disposition
    }
}
