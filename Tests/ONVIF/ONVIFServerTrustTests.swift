@testable import LemurCam
import XCTest

/// A camera's own certificate is self-signed, so with Use HTTPS on every request
/// failed with a TLS error. The client now accepts what macOS trusts, or exactly the
/// certificate the user trusted for the camera, and refuses any other with its
/// fingerprint, for the user to decide on. Certificates are evaluated offline.
internal final class ONVIFServerTrustTests: XCTestCase {
    private typealias Trust = ONVIFServerTrust

    // MARK: - The decision

    func testACertificateMacOSTrustsIsAcceptedWhateverIsPinned() {
        let leaf = TestCertificate.otherFingerprint
        XCTAssertEqual(Trust.decision(systemTrusted: true, leaf: leaf, pin: nil), .trustedBySystem)
        XCTAssertEqual(Trust.decision(systemTrusted: true, leaf: leaf, pin: leaf), .trustedBySystem)
    }

    func testThePinnedCertificateIsAccepted() {
        let leaf = TestCertificate.otherFingerprint
        XCTAssertEqual(Trust.decision(systemTrusted: false, leaf: leaf, pin: leaf), .matchesPin)
    }

    func testAnotherCertificateThanThePinnedOneIsRefusedAsChanged() {
        let leaf = CertificateFingerprint(certificateData: TestCertificate.der)
        XCTAssertEqual(
            Trust.decision(systemTrusted: false, leaf: leaf, pin: TestCertificate.otherFingerprint),
            .refused(.changed, fingerprint: leaf)
        )
    }

    func testAnUntrustedCertificateWithNothingPinnedIsRefusedAsUntrusted() {
        let leaf = TestCertificate.otherFingerprint
        XCTAssertEqual(
            Trust.decision(systemTrusted: false, leaf: leaf, pin: nil), .refused(.untrusted, fingerprint: leaf)
        )
    }

    /// Nothing to show the user, nor to match: refused, with no fingerprint.
    func testNoCertificateAtAllIsRefused() {
        XCTAssertEqual(
            Trust.decision(systemTrusted: false, leaf: nil, pin: TestCertificate.otherFingerprint),
            .refused(.changed, fingerprint: nil)
        )
    }

    // MARK: - With a real certificate

    func testASelfSignedCertificateIsNotTrustedByMacOS() throws {
        let leaf = CertificateFingerprint(certificateData: TestCertificate.der)
        XCTAssertEqual(try TestCertificate.decision(pin: nil), .refused(.untrusted, fingerprint: leaf))
    }

    func testTheSelfSignedCertificateIsAcceptedOncePinnedWhateverTheHost() throws {
        let pin = try XCTUnwrap(CertificateFingerprint(TestCertificate.opensslFingerprint))
        // The certificate names camera.test; the camera is reached by its IP address.
        XCTAssertEqual(try TestCertificate.decision(pin: pin, host: "192.0.2.10"), .matchesPin)
    }

    func testTheSelfSignedCertificateIsRefusedAsChangedWhenAnotherIsPinned() throws {
        XCTAssertEqual(
            try TestCertificate.decision(pin: TestCertificate.otherFingerprint),
            .refused(.changed, fingerprint: CertificateFingerprint(certificateData: TestCertificate.der))
        )
    }

    func testACertificateThatChainsToATrustedAnchorIsTrustedBySystem() throws {
        XCTAssertEqual(
            try TestCertificate.decision(pin: TestCertificate.otherFingerprint, anchored: true), .trustedBySystem
        )
    }

    // MARK: - The session delegate

    func testTheDelegateLetsTheSystemHandleATrustedCertificate() throws {
        let delegate = ONVIFServerTrustDelegate(host: "camera.test", pin: nil)
        let disposition = TestCertificate.present(try TestCertificate.serverTrust(anchored: true), to: delegate)
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(delegate.lastRefusal)
    }

    func testTheDelegateAcceptsThePinnedCertificate() throws {
        let pin = CertificateFingerprint(certificateData: TestCertificate.der)
        let delegate = ONVIFServerTrustDelegate(host: "192.0.2.10", pin: pin)
        XCTAssertEqual(TestCertificate.present(try TestCertificate.serverTrust(), to: delegate), .useCredential)
        XCTAssertNil(delegate.lastRefusal)
    }

    func testTheDelegateCancelsAndRecordsARefusedCertificate() throws {
        let presented = CertificateFingerprint(certificateData: TestCertificate.der)
        let untrusting = ONVIFServerTrustDelegate(host: "192.0.2.10", pin: nil)
        XCTAssertEqual(
            TestCertificate.present(try TestCertificate.serverTrust(), to: untrusting), .cancelAuthenticationChallenge
        )
        XCTAssertEqual(
            untrusting.lastRefusal,
            ONVIFCertificateProblem(kind: .untrusted, host: "192.0.2.10", fingerprint: presented)
        )

        let pinned = ONVIFServerTrustDelegate(host: "192.0.2.10", pin: TestCertificate.otherFingerprint)
        TestCertificate.present(try TestCertificate.serverTrust(), to: pinned)
        XCTAssertEqual(pinned.lastRefusal?.kind, .changed)
        XCTAssertEqual(pinned.lastRefusal?.fingerprint, presented)
    }

    // MARK: - The client

    /// The refused certificate is what the request fails with, at once: GetCapabilities
    /// used to fall back to the default media path and ask again.
    func testARequestMeetingARefusedCertificateFailsWithItAndNothingMoreIsAsked() async throws {
        let host = "onvif-refused-\(UUID().uuidString).invalid"
        let requests = CapturedBodies()
        ONVIFStubURLProtocol.register(host: host) { _, body in
            requests.append(body)
            return .failing(with: .cancelled)
        }
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let client = ONVIFClient(
            host: host, port: 443, username: "viewer", password: "pw", useHTTPS: true,
            configuration: ONVIFStubURLProtocol.configuration()
        )
        TestCertificate.present(try TestCertificate.serverTrust(), to: client.serverTrust)

        do {
            _ = try await client.getProfiles()
            XCTFail("expected the certificate to be refused")
        } catch ONVIFError.certificateNotTrusted(let problem) {
            XCTAssertEqual(problem.kind, .untrusted)
            XCTAssertEqual(problem.host, host)
            XCTAssertEqual(problem.fingerprint.formatted, TestCertificate.opensslFingerprint)
        }
        XCTAssertEqual(requests.all.count, 1)
    }

    // MARK: - Fingerprints

    func testTheFingerprintIsWrittenAsOpenSSLPrintsIt() {
        XCTAssertEqual(
            CertificateFingerprint(certificateData: TestCertificate.der).formatted, TestCertificate.opensslFingerprint
        )
    }

    func testAFingerprintIsReadWithOrWithoutColonsInEitherCase() {
        let expected = CertificateFingerprint(certificateData: TestCertificate.der)
        let bare = TestCertificate.opensslFingerprint.replacingOccurrences(of: ":", with: "")
        XCTAssertEqual(CertificateFingerprint(TestCertificate.opensslFingerprint), expected)
        XCTAssertEqual(CertificateFingerprint(bare.lowercased()), expected)
        XCTAssertEqual(CertificateFingerprint(" \(bare) "), expected)
    }

    func testAnythingButSixtyFourHexDigitsIsNoFingerprint() {
        let bare = TestCertificate.opensslFingerprint.replacingOccurrences(of: ":", with: "")
        let cases = [
            "", String(bare.dropLast(2)), bare + "00", "+" + String(bare.dropFirst()), "ZZ" + bare.dropFirst(2)
        ]
        for text in cases {
            XCTAssertNil(CertificateFingerprint(text), text)
        }
    }

    func testTheRefusalMessageNamesTheHostAndWhereToReviewIt() {
        let fingerprint = CertificateFingerprint(certificateData: TestCertificate.der)
        let changed = ONVIFError.certificateNotTrusted(
            ONVIFCertificateProblem(kind: .changed, host: "192.0.2.10", fingerprint: fingerprint)
        )
        let untrusted = ONVIFError.certificateNotTrusted(
            ONVIFCertificateProblem(kind: .untrusted, host: "cam.local", fingerprint: fingerprint)
        )
        XCTAssertEqual(
            changed.localizedDescription,
            "The certificate of the camera at 192.0.2.10 changed. "
                + "Open the camera in Settings and click Fetch Profiles to review it."
        )
        XCTAssertTrue(
            untrusted.localizedDescription.hasPrefix("The certificate of the camera at cam.local isn't trusted.")
        )
        XCTAssertFalse(changed.isTransportFailure)
        XCTAssertFalse(changed.isHostUnreachable)
        XCTAssertTrue(changed.needsUserDecision)
    }
}
