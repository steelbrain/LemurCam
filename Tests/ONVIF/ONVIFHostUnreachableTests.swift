@testable import LemurCam
import XCTest

/// Which ONVIF failures mean the camera's host couldn't be reached at all, the ones
/// that show the Local Network hint. Every failure with no answer used to count,
/// including a timeout and a failed TLS handshake, so an ONVIF camera whose HTTP
/// service hung, or whose certificate wasn't trusted, showed the hint. Cameras are
/// stubbed with `ONVIFStubURLProtocol`; nothing goes on the network.
internal final class ONVIFHostUnreachableTests: XCTestCase {
    private var stubbedHosts: [String] = []

    override func setUp() {
        super.setUp()
        stubbedHosts = []
    }

    override func tearDown() {
        stubbedHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        stubbedHosts = []
        super.tearDown()
    }

    // MARK: - Classification

    func testAFailedConnectIsUnreachable() {
        let codes: [URLError.Code] = [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
        for code in codes {
            XCTAssertTrue(ONVIFError.networkError("x", code: code).isHostUnreachable, "\(code)")
        }
    }

    func testATimeoutIsNotUnreachable() {
        XCTAssertFalse(ONVIFError.networkError("The request timed out.", code: .timedOut).isHostUnreachable)
        XCTAssertFalse(ONVIFError.timedOut.isHostUnreachable)
    }

    func testATLSFailureIsNotUnreachable() {
        let codes: [URLError.Code] = [
            .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateHasBadDate, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired
        ]
        for code in codes {
            XCTAssertFalse(ONVIFError.networkError("x", code: code).isHostUnreachable, "\(code)")
        }
    }

    /// A connection that was made and then dropped, a reply that broke off (no code),
    /// a cancelled request, and any answer from the device all reached the host.
    func testOtherFailuresAreNotUnreachable() {
        let errors: [ONVIFError] = [
            .networkError("x", code: .networkConnectionLost), .networkError("x", code: .cancelled),
            .networkError("x", code: .badServerResponse), .networkError("x"),
            .httpStatus(404), .soapFault("NotAuthorized"), .authenticationFailed, .parseError, .invalidURL
        ]
        for error in errors {
            XCTAssertFalse(error.isHostUnreachable, "\(error)")
        }
    }

    /// The code changes neither what is shown nor what counts as no answer at all, which
    /// decides whether the client falls back and whether a camera is looked for again.
    func testTheCodeChangesNeitherTheMessageNorTheTransportFailure() {
        let timedOut = ONVIFError.networkError("The request timed out.", code: .timedOut)
        XCTAssertEqual(timedOut.errorDescription, "Network error: The request timed out.")
        XCTAssertTrue(timedOut.isTransportFailure)
        XCTAssertTrue(ONVIFError.networkError("x", code: .serverCertificateUntrusted).isTransportFailure)
        XCTAssertTrue(ONVIFError.networkError("x", code: .cannotConnectToHost).isTransportFailure)
    }

    // MARK: - Through the client

    private struct UnexpectedStreamURI: Error {
        let uri: String
    }

    /// The error a stream-URI fetch from `host` throws; `failure` is how the stubbed
    /// camera's requests fail, nil for no camera at the address. Any other outcome
    /// is thrown.
    private func fetchError(host: String, failure: URLError.Code?) async throws -> ONVIFError {
        if let failure {
            stubbedHosts.append(host)
            ONVIFStubURLProtocol.register(host: host) { _, _ in .failing(with: failure) }
        }
        let client = ONVIFClient(
            host: host, port: 80, username: nil, password: nil, configuration: ONVIFStubURLProtocol.configuration()
        )
        do {
            throw UnexpectedStreamURI(uri: try await client.getStreamURI(profileToken: "main"))
        } catch let error as ONVIFError {
            return error
        }
    }

    func testTheClientKeepsTheCodeOfAFailedConnect() async throws {
        let error = try await fetchError(host: "onvif-unreachable-none.test", failure: nil)
        guard case .networkError(_, code: .cannotConnectToHost?) = error else {
            XCTFail("expected a network error with cannotConnectToHost, got \(error)")
            return
        }
        XCTAssertTrue(error.isHostUnreachable)
    }

    func testTheClientKeepsTheCodeOfATimeout() async throws {
        let error = try await fetchError(host: "onvif-unreachable-hung.test", failure: .timedOut)
        guard case .networkError(_, code: .timedOut?) = error else {
            XCTFail("expected a network error with timedOut, got \(error)")
            return
        }
        XCTAssertTrue(error.isTransportFailure)
        XCTAssertFalse(error.isHostUnreachable)
    }

    func testTheClientKeepsTheCodeOfAnUntrustedCertificate() async throws {
        let error = try await fetchError(host: "onvif-unreachable-tls.test", failure: .serverCertificateUntrusted)
        guard case .networkError(_, code: .serverCertificateUntrusted?) = error else {
            XCTFail("expected a network error with serverCertificateUntrusted, got \(error)")
            return
        }
        XCTAssertFalse(error.isHostUnreachable)
    }
}
