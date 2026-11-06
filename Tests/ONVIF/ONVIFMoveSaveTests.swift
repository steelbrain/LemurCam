@testable import LemurCam
import XCTest

/// After a rejected login or a SOAP fault at a camera's LAN address, rediscovery saved
/// the address the scan found before asking the camera there. The reply that matched
/// can come from another device claiming the same UUID (cloned firmware) while the
/// camera's own reply was lost, and the source was then re-pointed for good, and could
/// flip between the two on retries. After those failures a move is now saved only once
/// the camera gave its stream URI at the new address; after a transport failure it is
/// still saved before asking. Cameras and scans are stubbed; nothing goes on the
/// network.
@MainActor
internal final class ONVIFMoveSaveTests: XCTestCase {
    private var fixture: ONVIFResolveFixture?

    override func setUp() async throws {
        try await super.setUp()
        fixture = ONVIFResolveFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    private static let soapFault = ONVIFStubURLProtocol.Reply(status: 400, body: Data("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault>
        <s:Code><s:Value>s:Sender</s:Value></s:Code>
        <s:Reason><s:Text xml:lang="en">Sender not Authorized</s:Text></s:Reason>
        </s:Fault></s:Body></s:Envelope>
        """.utf8))

    /// Registers a camera at `host` that refuses every request with HTTP 401 and
    /// counts the signed ones, each of which is a failed login.
    private func stubRefusingCamera(host: String, harness: ONVIFResolveFixture) -> CapturedBodies {
        let logins = CapturedBodies()
        // Through the fixture first, so that its cleanUp removes the stub.
        harness.stub(host: host, ONVIFStubURLProtocol.Reply(status: 401))
        ONVIFStubURLProtocol.register(host: host) { _, body in
            if (try? ONVIFXML.parse(body))?["Header"]?["Security"] != nil { logins.append(body) }
            return ONVIFStubURLProtocol.Reply(status: 401)
        }
        return logins
    }

    /// The scan reply that matched can come from another device claiming the camera's
    /// UUID (cloned firmware) while the camera's own reply was lost. That device
    /// refuses the login too: the saved address is kept, not re-pointed for good.
    func testAMoveAfterARejectedLoginIsNotSavedWhenTheNewAddressRefusesItToo() async throws {
        let harness = try XCTUnwrap(fixture)
        _ = stubRefusingCamera(host: "192.168.77.80", harness: harness)
        let cloneLogins = stubRefusingCamera(host: "192.168.77.81", harness: harness)
        let source = try harness.addCamera(host: "192.168.77.80")
        let fileBefore = try harness.savedFile()

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.81")])
        )

        guard case .failure(let failure) = result, case .authenticationFailed? = failure.error as? ONVIFError else {
            XCTFail("the failed login at the new address must be reported, got \(result)")
            return
        }
        XCTAssertEqual(cloneLogins.all.count, 1)
        XCTAssertTrue(failure.cameraMoved, "the stored URI names the address the camera left")
        XCTAssertFalse(failure.allowsStoredURI)
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.80")
        XCTAssertEqual(try harness.savedFile(), fileBefore)
    }

    func testAMoveAfterASOAPFaultIsNotSavedWhenTheNewAddressFaultsToo() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.stub(host: "192.168.77.82", Self.soapFault)
        harness.stub(host: "192.168.77.83", Self.soapFault)
        let source = try harness.addCamera(host: "192.168.77.82")
        let fileBefore = try harness.savedFile()

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.83")])
        )

        guard case .failure(let failure) = result, case .soapFault? = failure.error as? ONVIFError else {
            XCTFail("expected the SOAP fault at the new address, got \(result)")
            return
        }
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.82")
        XCTAssertEqual(try harness.savedFile(), fileBefore)
    }

    /// Nor when nothing answers at the new address.
    func testAMoveAfterARejectedLoginIsNotSavedWhenNothingAnswersThere() async throws {
        let harness = try XCTUnwrap(fixture)
        _ = stubRefusingCamera(host: "192.168.77.84", harness: harness)
        let source = try harness.addCamera(host: "192.168.77.84")

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.85")])
        )

        XCTAssertNil(try? result.get())
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.84")
    }

    /// The swapped-cameras case still saves the move: the camera answered there.
    func testAMoveAfterARejectedLoginIsSavedOnceTheCameraAnswers() async throws {
        let harness = try XCTUnwrap(fixture)
        _ = stubRefusingCamera(host: "192.168.77.88", harness: harness)
        harness.stub(host: "192.168.77.89", ONVIFResolveFixture.streamURIReply("rtsp://192.168.77.89/main"))
        let source = try harness.addCamera(host: "192.168.77.88")

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.89")])
        )

        XCTAssertEqual(try result.get().uri, "rtsp://192.168.77.89/main")
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.89")
    }

    /// Another device answers at the saved address, and the scan finds the camera's
    /// UUID elsewhere, where nothing answers: the reply may have come from a device with
    /// a cloned UUID. The saved address is kept, and neither device got the login.
    func testAMoveAfterAnotherDeviceAnsweredIsNotSavedWhenNothingAnswersAtTheNewAddress() async throws {
        let harness = try XCTUnwrap(fixture)
        let otherDevice = "5f0c1d2e-0000-4000-8000-0000000000aa"
        harness.stub(host: "192.168.77.93", ONVIFResolveFixture.endpointReferenceReply(otherDevice))
        let source = try harness.addCamera(host: "192.168.77.93")
        let fileBefore = try harness.savedFile()

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.94")])
        )

        guard case .failure(let failure) = result else {
            XCTFail("nothing answers at the new address, got \(result)")
            return
        }
        XCTAssertTrue(failure.cameraMoved)
        XCTAssertFalse(failure.allowsStoredURI)
        XCTAssertEqual(harness.scanCount, 1)
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.93")
        XCTAssertEqual(try harness.savedFile(), fileBefore)
    }

    /// After a transport failure nothing at the saved address is the camera, so the
    /// move is saved before the new address is asked, as before: even when the camera
    /// does not answer there yet.
    func testAMoveAfterATransportFailureIsSavedBeforeAsking() async throws {
        let harness = try XCTUnwrap(fixture)
        let source = try harness.addCamera(host: "192.168.77.86")

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.87")])
        )

        XCTAssertNil(try? result.get(), "nothing answers at either address")
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.87")
    }

    /// The address is edited while the resolve looks for the camera. The move it
    /// found was for the address it started from, and overwrote the one just saved.
    func testAMoveIsNotSavedOverAnAddressSavedWhileTheCameraWasLookedFor() async throws {
        let harness = try XCTUnwrap(fixture)
        let source = try harness.addCamera(host: "192.168.77.90")
        let manager = harness.manager
        let edited = ONVIFSourceInfo(
            deviceUUID: ONVIFResolveFixture.deviceUUID, host: "192.168.77.92", port: 80, selectedProfileToken: "main"
        )

        _ = try await StreamCoordinator.attemptONVIFResolve(params: harness.params(
            for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.91")]
        ) {
            await MainActor.run {
                try? manager.updateSource(id: source.id, name: "Porch", sourceType: .onvif(edited), credentials: .keep)
            }
        })

        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.92")
    }

    func testWhichFailuresSaveAMoveOnlyOnceAnswered() {
        XCTAssertTrue(ONVIFRediscovery.savesMoveOnlyOnceAnswered(after: ONVIFError.authenticationFailed))
        XCTAssertTrue(ONVIFRediscovery.savesMoveOnlyOnceAnswered(after: ONVIFError.soapFault("Sender not Authorized")))
        XCTAssertTrue(ONVIFRediscovery.savesMoveOnlyOnceAnswered(after: ONVIFError.differentDevice(host: "h")))
        let before: [Error] = [
            ONVIFError.networkError("offline"), ONVIFError.timedOut, ONVIFError.httpStatus(404),
            ONVIFError.parseError, ONVIFError.invalidURL, CancellationError()
        ]
        for error in before {
            XCTAssertFalse(ONVIFRediscovery.savesMoveOnlyOnceAnswered(after: error), "\(error)")
        }
    }
}
