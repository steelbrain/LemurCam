@testable import LemurCam
import XCTest

/// A camera's stored stream URI is what is connected to, with the saved login, when a
/// later resolve fails. When WS-Discovery found the camera at a new address, the move
/// was saved but the stored URI kept naming the address the camera left, so that login
/// went to whatever device answers there now. The move now takes the URI along.
@MainActor
internal final class ONVIFMovedStreamURITests: XCTestCase {
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

    func testAMoveTakesTheStoredStreamURIAlong() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: InMemoryCredentialStore())
        let saved = ONVIFSourceInfo(
            deviceUUID: "2b9c0b1e-0000-4000-8000-00000000c0de", host: "192.168.1.20", port: 80,
            selectedProfileToken: "main", streamURI: "rtsp://192.168.1.20:554/main"
        )
        try manager.addSource(name: "Porch", sourceType: .onvif(saved))
        let id = try XCTUnwrap(manager.sources.first?.id)

        var moved = saved
        moved.host = "192.168.1.31"
        manager.updateONVIFAddress(id: id, from: saved, to: moved)

        guard case .onvif(let info) = manager.sources.first?.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.host, "192.168.1.31")
        XCTAssertEqual(info.streamURI, "rtsp://192.168.1.31:554/main")
        let reloaded = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: InMemoryCredentialStore())
        XCTAssertEqual(reloaded.sources.first?.sourceType, .onvif(info), "the move is saved with the URI")
    }

    func testOnlyAURINamingTheHostTheCameraLeftFollowsIt() {
        let move = { (uri: String, old: String, new: String) in
            SourceCredentials.storedStreamURI(uri, movedFrom: old, to: new)
        }
        XCTAssertEqual(move("rtsp://192.168.1.20/s?x=1", "192.168.1.20", "192.168.1.31"), "rtsp://192.168.1.31/s?x=1")
        XCTAssertEqual(move("rtsp://Cam.local:8554/s", "cam.local", "192.168.1.31"), "rtsp://192.168.1.31:8554/s")
        XCTAssertEqual(move("rtsp://[fe80::1]:554/s", "fe80::1", "fd00::5"), "rtsp://[fd00::5]:554/s")
        XCTAssertEqual(move("rtsp://192.168.1.20/s", "192.168.1.20", "[fd00::5]"), "rtsp://[fd00::5]/s")
        XCTAssertEqual(
            move("rtsp://192.168.1.50/s", "192.168.1.20", "192.168.1.31"), "rtsp://192.168.1.50/s",
            "a stream served from another host stays"
        )
        XCTAssertNil(move("not a url", "192.168.1.20", "192.168.1.31"))
        XCTAssertNil(move("rtsp://192.168.1.20/s", "192.168.1.20", "bad host"), "a host the URI can't hold drops it")
    }
}
