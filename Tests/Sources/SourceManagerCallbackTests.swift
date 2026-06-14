@testable import LemurCam
import XCTest

/// Locks which mutations fire `onSourceConfigChanged` (the hook `StreamCoordinator`
/// uses to resync the live stream) and the in-memory status/error bookkeeping.
/// Reordering fires nothing — a deliberate choice so dragging the list never
/// reconnects a stream — while add/remove/update/active-change all resync.
@MainActor
internal final class SourceManagerCallbackTests: XCTestCase {
    private var tempURL: URL?
    private var manager: SourceManager?
    private var savedActiveID: String?
    private var configChangeCount = 0

    override func setUp() async throws {
        try await super.setUp()
        configChangeCount = 0
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        guard let tempURL else { return }
        let sourceManager = SourceManager(storage: SourceStorage(fileURL: tempURL), keychain: KeychainService())
        sourceManager.onSourceConfigChanged = { [weak self] in self?.configChangeCount += 1 }
        self.manager = sourceManager
    }

    override func tearDown() async throws {
        if let sourceManager = manager {
            for source in sourceManager.sources { try? KeychainService().delete(for: source.id) }
        }
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

    private func addRTSP(_ name: String) {
        manager?.addSource(name: name, sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://\(name)")))
    }

    // MARK: - onSourceConfigChanged

    func testAddFiresConfigChanged() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        XCTAssertEqual(configChangeCount, 1)
        _ = sourceManager
    }

    func testUpdateFiresConfigChanged() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        let id = try XCTUnwrap(sourceManager.sources.first).id
        configChangeCount = 0

        sourceManager.updateSource(id: id, name: "b",
                                   sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")), credentials: nil)

        XCTAssertEqual(configChangeCount, 1)
    }

    func testRemoveFiresConfigChanged() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        let id = try XCTUnwrap(sourceManager.sources.first).id
        configChangeCount = 0

        sourceManager.removeSource(id: id)

        XCTAssertEqual(configChangeCount, 1)
    }

    func testSetActiveToDifferentSourceFires() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        addRTSP("b")
        let second = try XCTUnwrap(sourceManager.sources.last).id
        configChangeCount = 0

        sourceManager.setActiveSource(id: second)

        XCTAssertEqual(configChangeCount, 1)
        XCTAssertEqual(sourceManager.activeSourceID, second)
    }

    func testSetActiveToSameSourceDoesNotFire() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        let active = try XCTUnwrap(sourceManager.activeSourceID)
        configChangeCount = 0

        sourceManager.setActiveSource(id: active)

        XCTAssertEqual(configChangeCount, 0)
    }

    func testMoveSourceDoesNotFireConfigChanged() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        addRTSP("b")
        configChangeCount = 0

        sourceManager.moveSource(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(configChangeCount, 0)
        XCTAssertEqual(sourceManager.sources.first?.name, "b")
    }

    // MARK: - status & error bookkeeping

    func testSetActiveToNilClearsActiveSource() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        XCTAssertNotNil(sourceManager.activeSourceID)

        sourceManager.setActiveSource(id: nil)

        XCTAssertNil(sourceManager.activeSourceID)
    }

    func testUpdateConnectionStatusAndErrorMessageAreStored() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        let id = try XCTUnwrap(sourceManager.sources.first).id

        sourceManager.updateConnectionStatus(for: id, status: .error)
        sourceManager.updateErrorMessage(for: id, message: "boom")

        XCTAssertEqual(sourceManager.connectionStatuses[id], .error)
        XCTAssertEqual(sourceManager.errorMessages[id], "boom")
    }

    func testRemoveClearsStatusAndErrorEntries() throws {
        let sourceManager = try XCTUnwrap(manager)
        addRTSP("a")
        let id = try XCTUnwrap(sourceManager.sources.first).id
        sourceManager.updateConnectionStatus(for: id, status: .connected)
        sourceManager.updateErrorMessage(for: id, message: "x")

        sourceManager.removeSource(id: id)

        XCTAssertNil(sourceManager.connectionStatuses[id])
        XCTAssertNil(sourceManager.errorMessages[id])
    }
}
