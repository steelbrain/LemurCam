@testable import LemurCam
import XCTest

/// What the user decided about a camera at its saved address (the certificate trusted
/// there) is saved with it, decodes as nothing from a file saved before it existed,
/// and never follows the camera to another address without the user seeing it: not
/// when WS-Discovery finds it elsewhere, nor when an edit form opened before that move
/// is saved. Credentials go to an in-memory store.
@MainActor
internal final class ONVIFAddressDecisionsTests: XCTestCase {
    private static let pin = CertificateFingerprint(certificateData: TestCertificate.der)
    private static let saved = ONVIFSourceInfo(
        deviceUUID: ONVIFResolveFixture.deviceUUID, host: "192.168.1.20", port: 443,
        selectedProfileToken: "main", streamURI: "rtsp://192.168.1.20:554/main", useHTTPS: true,
        pinnedCertificate: pin
    )

    private var directory: URL?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - Saved and loaded

    func testASourceSavedBeforeThePinExistedDecodesWithNone() throws {
        let json = """
            { "deviceUUID": "dev-1", "host": "192.168.1.20", "port": 443, "useHTTPS": true,
              "selectedProfileToken": "main", "serialNumber": "SN-1" }
            """
        let info = try JSONDecoder().decode(ONVIFSourceInfo.self, from: Data(json.utf8))
        XCTAssertNil(info.pinnedCertificate)
        XCTAssertEqual(info.connectionPolicy, ONVIFConnectionPolicy())
        XCTAssertTrue(info.useHTTPS)
    }

    func testThePinIsSavedAsOpenSSLWritesItAndReadBack() throws {
        let data = try JSONEncoder().encode(Self.saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["pinnedCertificate"] as? String, TestCertificate.opensslFingerprint)
        XCTAssertEqual(try JSONDecoder().decode(ONVIFSourceInfo.self, from: data), Self.saved)
    }

    /// The camera's certificate is asked about again, rather than the cameras file
    /// failing to load.
    func testAPinThatCannotBeReadIsDropped() throws {
        let json = """
            { "host": "192.168.1.20", "port": 443, "useHTTPS": true, "pinnedCertificate": "not a fingerprint" }
            """
        let info = try JSONDecoder().decode(ONVIFSourceInfo.self, from: Data(json.utf8))
        XCTAssertNil(info.pinnedCertificate)
        XCTAssertEqual(info.host, "192.168.1.20")
    }

    // MARK: - Moves

    func testACameraFoundElsewhereByTheScanIsAskedThereWithoutThePin() {
        let found = ONVIFResolveFixture.device(host: "192.168.1.31", port: 443, useHTTPS: true)
        guard case .moved(let moved) = ONVIFRediscovery.outcome(for: Self.saved, among: [found]) else {
            XCTFail("expected a move")
            return
        }
        XCTAssertEqual(moved.host, "192.168.1.31")
        XCTAssertNil(moved.pinnedCertificate)
        XCTAssertNil(moved.connectionPolicy.pinnedCertificate)
    }

    func testASavedMoveDropsThePin() throws {
        let (manager, id) = try managerWithCamera()
        var moved = Self.saved
        moved.host = "192.168.1.31"

        manager.updateONVIFAddress(id: id, from: Self.saved, to: moved)

        let info = try XCTUnwrap(Self.onvifInfo(manager))
        XCTAssertEqual(info.host, "192.168.1.31")
        XCTAssertNil(info.pinnedCertificate)
    }

    /// The form loaded the camera with its pin at the old address; saving it after the
    /// move keeps the move and, with it, no pin.
    func testAnEditFormOpenedBeforeAMoveDoesNotCarryThePinThere() throws {
        let (manager, id) = try managerWithCamera()
        var moved = Self.saved
        moved.host = "192.168.1.31"
        manager.updateONVIFAddress(id: id, from: Self.saved, to: moved)

        try manager.updateSource(
            id: id, name: "Renamed", sourceType: .onvif(Self.saved), credentials: .keep,
            editedFrom: .onvif(Self.saved)
        )

        let info = try XCTUnwrap(Self.onvifInfo(manager))
        XCTAssertEqual(info.host, "192.168.1.31")
        XCTAssertNil(info.pinnedCertificate)
    }

    /// An edit that left the address alone keeps the pin it loaded.
    func testAnEditAtTheSameAddressKeepsThePin() throws {
        let (manager, id) = try managerWithCamera()

        try manager.updateSource(
            id: id, name: "Renamed", sourceType: .onvif(Self.saved), credentials: .keep,
            editedFrom: .onvif(Self.saved)
        )

        let info = try XCTUnwrap(Self.onvifInfo(manager))
        XCTAssertEqual(info.pinnedCertificate, Self.pin)
    }

    private func managerWithCamera() throws -> (SourceManager, UUID) {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: InMemoryCredentialStore())
        try manager.addSource(
            name: "Porch", sourceType: .onvif(Self.saved), credentials: ONVIFResolveFixture.credentials
        )
        return (manager, try XCTUnwrap(manager.sources.first?.id))
    }

    private static func onvifInfo(_ manager: SourceManager) -> ONVIFSourceInfo? {
        guard case .onvif(let info)? = manager.sources.first?.sourceType else { return nil }
        return info
    }
}
