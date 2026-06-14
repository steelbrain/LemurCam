@testable import LemurCam
import XCTest

internal final class SourceStorageTests: XCTestCase {
    private var tempURL: URL?
    private var storage: SourceStorage?

    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        guard let tempURL else { return }
        storage = SourceStorage(fileURL: tempURL)
    }

    override func tearDown() {
        guard let tempURL else { return }
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    func testLoadFromNonExistentReturnsEmpty() {
        guard let storage else { XCTFail("storage not initialized"); return }
        let sources = storage.load()
        XCTAssertTrue(sources.isEmpty)
    }

    func testSaveAndLoad() {
        guard let storage else { XCTFail("storage not initialized"); return }
        let sources = [
            CameraSource(name: "Cam 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a"))),
            CameraSource(name: "Cam 2", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        ]
        storage.save(sources)

        let loaded = storage.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, sources[0].id)
        XCTAssertEqual(loaded[1].name, "Cam 2")
    }

    func testOverwrite() {
        guard let storage else { XCTFail("storage not initialized"); return }
        let first = [CameraSource(name: "Old", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://old")))]
        storage.save(first)

        let second = [CameraSource(name: "New", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://new")))]
        storage.save(second)

        let loaded = storage.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "New")
    }

    func testSaveEmptyList() {
        guard let storage else { XCTFail("storage not initialized"); return }
        let sources = [CameraSource(name: "X", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://x")))]
        storage.save(sources)
        storage.save([])

        let loaded = storage.load()
        XCTAssertTrue(loaded.isEmpty)
    }
}
