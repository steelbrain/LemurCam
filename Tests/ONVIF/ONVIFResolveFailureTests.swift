@testable import LemurCam
import XCTest

/// A failed ONVIF resolve used to return a bare nil, so the source list showed
/// "Could not reach camera" even when the camera had answered and rejected the login.
/// The resolve now returns the error, and the coordinator shows its description when
/// there is no stored URI to fall back on. Nothing here goes on the network: cameras
/// are stubbed and the scan is replaced.
internal final class ONVIFResolveFailureTests: XCTestCase {
    /// Running out of the overall budget is reported as a timeout, so the source list
    /// can say the camera did not answer in time.
    func testOverallTimeoutIsReportedAsTimedOut() async {
        let info = ONVIFSourceInfo(
            deviceUUID: "2b9c0b1e-0000-4000-8000-00000000c0de",
            host: "onvif-resolve-unregistered-\(UUID().uuidString).invalid", port: 80, selectedProfileToken: "main"
        )
        let environment = ONVIFResolveEnvironment(
            scan: {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return []
            },
            makeClient: { info, _ in
                ONVIFClient(host: info.host, port: info.port, username: nil, password: nil,
                            configuration: ONVIFStubURLProtocol.configuration())
            }
        )
        let params = ONVIFResolveParams(
            info: info, token: "main", credentials: nil, sourceID: UUID(), sourceName: "Porch",
            sourceManager: nil, environment: environment
        )

        let result = await StreamCoordinator.resolveONVIFStreamURI(params: params, timeout: 0.3)

        guard case .failure(let failure) = result, case .timedOut? = failure.error as? ONVIFError else {
            XCTFail("expected a timeout, got \(result)")
            return
        }
    }

    /// The message the coordinator shows when nothing can be connected to.
    func testFailureMessageDescribesTheCameraAnswer() {
        XCTAssertEqual(StreamCoordinator.onvifResolveFailureMessage(for: ONVIFError.authenticationFailed),
                       "Authentication failed")
        XCTAssertEqual(StreamCoordinator.onvifResolveFailureMessage(for: ONVIFError.soapFault("Sender not Authorized")),
                       "ONVIF error: Sender not Authorized")
        XCTAssertEqual(StreamCoordinator.onvifResolveFailureMessage(for: ONVIFError.httpStatus(404)),
                       "Network error: HTTP 404")
        XCTAssertEqual(StreamCoordinator.onvifResolveFailureMessage(for: ONVIFXML.Rejection.malformed),
                       "The camera's response is not valid XML")
        XCTAssertEqual(StreamCoordinator.onvifResolveFailureMessage(for: CancellationError()), "Could not reach camera")
    }
}
