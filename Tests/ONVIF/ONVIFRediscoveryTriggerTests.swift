@testable import LemurCam
import XCTest

/// Rediscovery ran only when the saved address gave no answer at all. After a DHCP
/// change the address can belong to another device that does answer, with an HTTP
/// 404 or a web page, and the camera was never looked for again. Those answers now
/// lead to a scan too. So do a rejected login and a SOAP fault at a LAN IP address:
/// after a router reset two cameras can swap addresses, and the other camera refuses
/// this one's login (or profile) on every retry. The tests also pin the protection
/// against the old rediscovery loop: a camera found where it was saves nothing and is
/// not asked again, and a saved move changes neither `updatedAt` nor fires a config
/// change. Cameras and scans are stubbed; nothing goes on the network.
@MainActor
internal final class ONVIFRediscoveryTriggerTests: XCTestCase {
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

    private static let webPage = ONVIFStubURLProtocol.Reply(
        headers: ["Content-Type": "text/html"],
        body: Data("<!DOCTYPE html><html><body>Router login</body></html>".utf8)
    )

    private static let soapFault = ONVIFStubURLProtocol.Reply(status: 400, body: Data("""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault>
        <s:Code><s:Value>s:Sender</s:Value></s:Code>
        <s:Reason><s:Text xml:lang="en">Sender not Authorized</s:Text></s:Reason>
        </s:Fault></s:Body></s:Envelope>
        """.utf8))

    /// Another device now at the old address answers 404; the scan finds the camera
    /// at its new address, where the stream URI is fetched and the move is saved.
    func testHTTPErrorFromAnotherDeviceFindsTheMovedCamera() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.stub(host: "192.168.77.20", ONVIFStubURLProtocol.Reply(status: 404))
        harness.stub(host: "192.168.77.31", ONVIFResolveFixture.streamURIReply("rtsp://192.168.77.31/main"))
        let source = try harness.addCamera(host: "192.168.77.20")
        var configChanges = 0
        harness.manager.onSourceConfigChanged = { configChanges += 1 }

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.31")])
        )

        XCTAssertEqual(try result.get().uri, "rtsp://192.168.77.31/main")
        XCTAssertEqual(try result.get().onvifHost, "192.168.77.31", "the URI came from the address the scan found")
        XCTAssertEqual(harness.scanCount, 1)
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.31")
        XCTAssertEqual(harness.manager.sources.first?.updatedAt, source.updatedAt, "a move is not a user edit")
        XCTAssertEqual(configChanges, 0, "saving the move must not restart the resolve")
    }

    /// A web page (here with a DOCTYPE, which the XML guard rejects) is not the
    /// camera's ONVIF service either.
    func testWebPageFromAnotherDeviceTriggersAScan() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.stub(host: "192.168.77.21", Self.webPage)
        let source = try harness.addCamera(host: "192.168.77.21")

        _ = try await StreamCoordinator.attemptONVIFResolve(params: harness.params(for: source, scanResult: []))

        XCTAssertEqual(harness.scanCount, 1)
    }

    /// The loop's trigger, now reachable from more errors: the scan finds the camera
    /// where it was saved. Nothing is written and nothing restarts the resolve.
    func testUnmovedCameraAfterHTTPErrorSavesNothing() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.stub(host: "192.168.77.22", ONVIFStubURLProtocol.Reply(status: 404))
        let source = try harness.addCamera(host: "192.168.77.22")
        let fileBefore = try harness.savedFile()
        let writesBefore = harness.store.writes
        var configChanges = 0
        harness.manager.onSourceConfigChanged = { configChanges += 1 }

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.22")])
        )

        guard case .failure(let error) = result, case .httpStatus(404)? = error as? ONVIFError else {
            XCTFail("the saved address's answer must be reported, got \(result)")
            return
        }
        XCTAssertEqual(harness.scanCount, 1)
        XCTAssertEqual(harness.manager.sources.first, source)
        XCTAssertEqual(try harness.savedFile(), fileBefore)
        XCTAssertEqual(harness.store.writes, writesBefore)
        XCTAssertEqual(configChanges, 0)
    }

    /// A SOAP fault at a LAN IP address may come from another camera now at it, so the
    /// camera is looked for. Found where it was saved, the fault is its own: it is
    /// reported, nothing is written and nothing restarts the resolve.
    func testSOAPFaultFromTheCameraItselfScansAndSavesNothing() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.stub(host: "192.168.77.23", Self.soapFault)
        let source = try harness.addCamera(host: "192.168.77.23")
        let fileBefore = try harness.savedFile()
        var configChanges = 0
        harness.manager.onSourceConfigChanged = { configChanges += 1 }

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.23")])
        )

        guard case .failure(let error) = result, case .soapFault? = error as? ONVIFError else {
            XCTFail("expected the camera's SOAP fault, got \(result)")
            return
        }
        XCTAssertEqual(harness.scanCount, 1)
        XCTAssertEqual(harness.manager.sources.first, source)
        XCTAssertEqual(try harness.savedFile(), fileBefore)
        XCTAssertEqual(configChanges, 0)
    }

    // MARK: - Swapped addresses

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

    /// The reported case: after a router reset the camera's LAN address belongs to
    /// another camera, which refuses its login. It used to be asked again on every
    /// retry, a failed login each time. The scan finds the camera at its new address,
    /// which is saved and asked; the other camera saw a single login.
    func testRejectedLoginAtALANAddressFindsTheSwappedCamera() async throws {
        let harness = try XCTUnwrap(fixture)
        let otherCameraLogins = stubRefusingCamera(host: "192.168.77.70", harness: harness)
        harness.stub(host: "192.168.77.71", ONVIFResolveFixture.streamURIReply("rtsp://192.168.77.71/main"))
        let source = try harness.addCamera(host: "192.168.77.70")
        var configChanges = 0
        harness.manager.onSourceConfigChanged = { configChanges += 1 }
        let writesBefore = harness.store.writes

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.71")])
        )

        XCTAssertEqual(try result.get().uri, "rtsp://192.168.77.71/main")
        XCTAssertEqual(harness.scanCount, 1)
        XCTAssertEqual(otherCameraLogins.all.count, 1)
        XCTAssertEqual(harness.savedInfo(source)?.host, "192.168.77.71")
        XCTAssertEqual(harness.manager.sources.first?.updatedAt, source.updatedAt, "a move is not a user edit")
        XCTAssertEqual(configChanges, 0, "saving the move must not restart the resolve")
        XCTAssertEqual(harness.store.writes, writesBefore, "rediscovery must not rewrite credentials")
    }

    /// A wrong password at the camera's own address: the scan (which sends no login)
    /// finds the camera where it is saved. It is not asked again, nothing is written,
    /// nothing restarts the resolve, and the failed login is what is reported.
    func testRejectedLoginByTheCameraItselfIsOneLoginAndSavesNothing() async throws {
        let harness = try XCTUnwrap(fixture)
        let logins = stubRefusingCamera(host: "192.168.77.72", harness: harness)
        let source = try harness.addCamera(host: "192.168.77.72")
        let fileBefore = try harness.savedFile()
        let writesBefore = harness.store.writes
        var configChanges = 0
        harness.manager.onSourceConfigChanged = { configChanges += 1 }

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.72")])
        )

        guard case .failure(let error) = result, case .authenticationFailed? = error as? ONVIFError else {
            XCTFail("the failed login must be reported, got \(result)")
            return
        }
        XCTAssertEqual(harness.scanCount, 1)
        XCTAssertEqual(logins.all.count, 1, "one failed login per resolve")
        XCTAssertEqual(harness.manager.sources.first, source)
        XCTAssertEqual(try harness.savedFile(), fileBefore)
        XCTAssertEqual(harness.store.writes, writesBefore)
        XCTAssertEqual(configChanges, 0)
    }

    /// The camera did not answer the scan (or several addresses claim it): the saved
    /// address is kept and the failed login is reported, after that one login.
    func testRejectedLoginWithoutTheCameraFoundKeepsTheSavedAddress() async throws {
        let harness = try XCTUnwrap(fixture)
        let logins = stubRefusingCamera(host: "192.168.77.73", harness: harness)
        let source = try harness.addCamera(host: "192.168.77.73")
        let ambiguous = ["192.168.77.74", "192.168.77.75"].map { ONVIFResolveFixture.device(host: $0) }

        for scanResult in [[], ambiguous] {
            let result = try await StreamCoordinator.attemptONVIFResolve(
                params: harness.params(for: source, scanResult: scanResult)
            )

            guard case .failure(let error) = result, case .authenticationFailed? = error as? ONVIFError else {
                XCTFail("the failed login must be reported, got \(result)")
                return
            }
            XCTAssertEqual(harness.manager.sources.first, source)
        }
        XCTAssertEqual(harness.scanCount, 2)
        XCTAssertEqual(logins.all.count, 2, "one failed login per resolve")
    }

    /// A camera saved by a host name keeps that name whatever a scan finds, so a
    /// rejected login there is not followed by a scan: it is the named camera's answer.
    func testRejectedLoginAtAHostNameDoesNotScan() async throws {
        let harness = try XCTUnwrap(fixture)
        let logins = stubRefusingCamera(host: "porch-cam.local", harness: harness)
        let source = try harness.addCamera(host: "porch-cam.local")

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.71")])
        )

        guard case .failure(let error) = result, case .authenticationFailed? = error as? ONVIFError else {
            XCTFail("the failed login must be reported, got \(result)")
            return
        }
        XCTAssertEqual(harness.scanCount, 0)
        XCTAssertEqual(logins.all.count, 1)
        XCTAssertEqual(harness.manager.sources.first, source)
    }
}
