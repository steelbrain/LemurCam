@testable import LemurCam
import XCTest

/// Rediscovery ran only when the saved address gave no answer at all. After a DHCP
/// change the address can belong to another device that does answer, with an HTTP
/// 404 or a web page, and the camera was never looked for again. Those answers now
/// lead to a scan too; the camera's own login rejections and SOAP faults still do not.
/// The tests also pin the protection against the old rediscovery loop: a camera found
/// where it was saves nothing, and a saved move changes neither `updatedAt` nor fires
/// a config change. Cameras and scans are stubbed; nothing goes on the network.
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

        XCTAssertEqual(try result.get(), "rtsp://192.168.77.31/main")
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

    /// A SOAP fault is the camera itself refusing the request: no scan.
    func testSOAPFaultFromTheCameraDoesNotScan() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.stub(host: "192.168.77.23", Self.soapFault)
        let source = try harness.addCamera(host: "192.168.77.23")

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.31")])
        )

        guard case .failure(let error) = result, case .soapFault? = error as? ONVIFError else {
            XCTFail("expected the camera's SOAP fault, got \(result)")
            return
        }
        XCTAssertEqual(harness.scanCount, 0)
        XCTAssertEqual(harness.manager.sources.first, source)
    }
}
