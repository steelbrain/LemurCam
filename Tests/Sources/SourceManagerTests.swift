@testable import LemurCam
import XCTest

@MainActor
internal final class SourceManagerTests: XCTestCase {
    private var tempURL: URL?
    private var manager: SourceManager?
    /// Stands in for the Keychain, so the tests never read or write the real one.
    private let credentialStore = InMemoryCredentialStore()
    /// `SourceManager` saves the active camera in the test host's standard defaults;
    /// `tearDown` puts back what was there.
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        guard let tempURL else { return }
        let storage = SourceStorage(fileURL: tempURL)
        manager = SourceManager(storage: storage, keychain: credentialStore)
    }

    override func tearDown() async throws {
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
        try await super.tearDown()
    }

    func testAddFirstSourceBecomesActive() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))

        XCTAssertEqual(manager.sources.count, 1)
        XCTAssertEqual(manager.activeSourceID, manager.sources[0].id)
    }

    func testAddSecondSourceDoesNotChangeActive() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let firstID = manager.sources[0].id

        try manager.addSource(name: "Camera 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))

        XCTAssertEqual(manager.sources.count, 2)
        XCTAssertEqual(manager.activeSourceID, firstID)
    }

    func testRemoveActiveSourceFallsBack() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        try manager.addSource(name: "Camera 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        let firstID = manager.sources[0].id
        let secondID = manager.sources[1].id

        manager.removeSource(id: firstID)

        XCTAssertEqual(manager.sources.count, 1)
        XCTAssertEqual(manager.activeSourceID, secondID)
    }

    func testRemoveOnlySourceClearsActive() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let id = manager.sources[0].id

        manager.removeSource(id: id)

        XCTAssertTrue(manager.sources.isEmpty)
        XCTAssertNil(manager.activeSourceID)
    }

    func testSwitchActiveSource() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        try manager.addSource(name: "Camera 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        let secondID = manager.sources[1].id

        manager.setActiveSource(id: secondID)

        XCTAssertEqual(manager.activeSourceID, secondID)
    }

    func testSwitchToInvalidIDIsIgnored() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let originalActive = manager.activeSourceID

        manager.setActiveSource(id: UUID())

        XCTAssertEqual(manager.activeSourceID, originalActive)
    }

    func testUpdateSource() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "Old Name", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://old")))
        let id = manager.sources[0].id

        try manager.updateSource(id: id, name: "New Name",
                                 sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://new")),
                                 credentials: .remove)

        XCTAssertEqual(manager.sources[0].name, "New Name")
        if case .rtsp(let info) = manager.sources[0].sourceType {
            XCTAssertEqual(info.url, "rtsp://new")
        } else {
            XCTFail("Expected RTSP source type")
        }
    }

    func testCredentialsPersistWithSource() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        let creds = SourceCredentials(username: "admin", password: "pass123")
        try manager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")),
                              credentials: creds)
        let id = manager.sources[0].id

        let retrieved = manager.credentials(for: id)
        XCTAssertEqual(retrieved, creds)
    }

    func testRemoveSourceDeletesCredentials() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        let creds = SourceCredentials(username: "admin", password: "pass")
        try manager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")),
                              credentials: creds)
        let id = manager.sources[0].id

        manager.removeSource(id: id)

        let retrieved = manager.credentials(for: id)
        XCTAssertNil(retrieved)
    }

    func testPersistenceRoundTrip() throws {
        guard let manager, let tempURL else { XCTFail("manager or tempURL not initialized"); return }
        try manager.addSource(name: "Cam 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        try manager.addSource(name: "Cam 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        let secondID = manager.sources[1].id
        manager.setActiveSource(id: secondID)

        // Create a new manager pointing to the same storage
        let storage = SourceStorage(fileURL: tempURL)
        let newManager = SourceManager(storage: storage, keychain: credentialStore)
        newManager.load()

        XCTAssertEqual(newManager.sources.count, 2)
        XCTAssertEqual(newManager.sources[0].name, "Cam 1")
        XCTAssertEqual(newManager.sources[1].name, "Cam 2")
        XCTAssertEqual(newManager.activeSourceID, secondID)
    }

    func testMoveSource() throws {
        guard let manager else { XCTFail("manager not initialized"); return }
        try manager.addSource(name: "A", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        try manager.addSource(name: "B", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        try manager.addSource(name: "C", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://c")))

        manager.moveSource(from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(manager.sources[0].name, "C")
        XCTAssertEqual(manager.sources[1].name, "A")
        XCTAssertEqual(manager.sources[2].name, "B")
    }
}
