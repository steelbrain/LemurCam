@testable import LemurCam
import XCTest

@MainActor
internal final class SourceManagerTests: XCTestCase {
    private var tempURL: URL?
    private var manager: SourceManager?

    override func setUp() async throws {
        try await super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        guard let tempURL else { return }
        let storage = SourceStorage(fileURL: tempURL)
        let keychain = KeychainService()
        manager = SourceManager(storage: storage, keychain: keychain)
    }

    override func tearDown() async throws {
        // Clean up sources from keychain
        if let manager {
            for source in manager.sources {
                try? KeychainService().delete(for: source.id)
            }
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
        try await super.tearDown()
    }

    func testAddFirstSourceBecomesActive() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))

        XCTAssertEqual(manager.sources.count, 1)
        XCTAssertEqual(manager.activeSourceID, manager.sources[0].id)
    }

    func testAddSecondSourceDoesNotChangeActive() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let firstID = manager.sources[0].id

        manager.addSource(name: "Camera 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))

        XCTAssertEqual(manager.sources.count, 2)
        XCTAssertEqual(manager.activeSourceID, firstID)
    }

    func testRemoveActiveSourceFallsBack() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        manager.addSource(name: "Camera 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        let firstID = manager.sources[0].id
        let secondID = manager.sources[1].id

        manager.removeSource(id: firstID)

        XCTAssertEqual(manager.sources.count, 1)
        XCTAssertEqual(manager.activeSourceID, secondID)
    }

    func testRemoveOnlySourceClearsActive() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let id = manager.sources[0].id

        manager.removeSource(id: id)

        XCTAssertTrue(manager.sources.isEmpty)
        XCTAssertNil(manager.activeSourceID)
    }

    func testSwitchActiveSource() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        manager.addSource(name: "Camera 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        let secondID = manager.sources[1].id

        manager.setActiveSource(id: secondID)

        XCTAssertEqual(manager.activeSourceID, secondID)
    }

    func testSwitchToInvalidIDIsIgnored() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let originalActive = manager.activeSourceID

        manager.setActiveSource(id: UUID())

        XCTAssertEqual(manager.activeSourceID, originalActive)
    }

    func testUpdateSource() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "Old Name", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://old")))
        let id = manager.sources[0].id

        manager.updateSource(id: id, name: "New Name",
                             sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://new")),
                             credentials: nil)

        XCTAssertEqual(manager.sources[0].name, "New Name")
        if case .rtsp(let info) = manager.sources[0].sourceType {
            XCTAssertEqual(info.url, "rtsp://new")
        } else {
            XCTFail("Expected RTSP source type")
        }
    }

    func testCredentialsPersistWithSource() {
        guard let manager else { XCTFail("manager not initialized"); return }
        let creds = SourceCredentials(username: "admin", password: "pass123")
        manager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")),
                          credentials: creds)
        let id = manager.sources[0].id

        let retrieved = manager.credentials(for: id)
        XCTAssertEqual(retrieved, creds)
    }

    func testRemoveSourceDeletesCredentials() {
        guard let manager else { XCTFail("manager not initialized"); return }
        let creds = SourceCredentials(username: "admin", password: "pass")
        manager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")),
                          credentials: creds)
        let id = manager.sources[0].id

        manager.removeSource(id: id)

        let retrieved = manager.credentials(for: id)
        XCTAssertNil(retrieved)
    }

    func testPersistenceRoundTrip() {
        guard let manager, let tempURL else { XCTFail("manager or tempURL not initialized"); return }
        manager.addSource(name: "Cam 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        manager.addSource(name: "Cam 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        let secondID = manager.sources[1].id
        manager.setActiveSource(id: secondID)

        // Create a new manager pointing to the same storage
        let storage = SourceStorage(fileURL: tempURL)
        let newManager = SourceManager(storage: storage, keychain: KeychainService())
        newManager.load()

        XCTAssertEqual(newManager.sources.count, 2)
        XCTAssertEqual(newManager.sources[0].name, "Cam 1")
        XCTAssertEqual(newManager.sources[1].name, "Cam 2")
        XCTAssertEqual(newManager.activeSourceID, secondID)
    }

    func testMoveSource() {
        guard let manager else { XCTFail("manager not initialized"); return }
        manager.addSource(name: "A", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        manager.addSource(name: "B", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        manager.addSource(name: "C", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://c")))

        manager.moveSource(from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(manager.sources[0].name, "C")
        XCTAssertEqual(manager.sources[1].name, "A")
        XCTAssertEqual(manager.sources[2].name, "B")
    }
}
