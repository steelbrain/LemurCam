@testable import LemurCam
import XCTest

/// Two ways `sources.json` failed without a word. When its folder lost search
/// permission the file looked missing, so the app showed no cameras and the next
/// save could overwrite the intact file once permission came back; it now counts as
/// unreadable. And a save that failed (disk full, folder not writable) was only
/// logged; it is now shown in Settings → Cameras until a save works, or, for a camera
/// added, edited or removed, undone with an error.
@MainActor
internal final class SourceSaveFailureTests: XCTestCase {
    private var directory: URL?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        // `addSource` saves the active camera in the host app's standard defaults.
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let directory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    private let savedCamera = """
        [{"id": "11111111-1111-1111-1111-111111111111", "name": "Saved",
          "createdAt": "2026-01-02T03:04:05Z", "updatedAt": "2026-01-02T03:04:05Z",
          "sourceType": {"rtsp": {"_0": {"url": "rtsp://192.0.2.1/s"}}}}]
        """

    private func write(_ json: String) throws -> URL {
        let dir = try XCTUnwrap(directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sources.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func setFolderPermissions(_ permissions: Int) throws {
        let dir = try XCTUnwrap(directory)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: dir.path)
    }

    private func savedNames(in url: URL) throws -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CameraSource].self, from: Data(contentsOf: url)).map(\.name)
    }

    func testAFileInAFolderThatCantBeSearchedIsUnreadableRatherThanMissing() throws {
        let url = try write(savedCamera)
        try setFolderPermissions(0o644)
        let storage = SourceStorage(fileURL: url)

        XCTAssertEqual(storage.load(), [])
        XCTAssertEqual(storage.saveRefusal, .unreadable)
        storage.save([])

        try setFolderPermissions(0o755)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), savedCamera, "the file is not saved over")
    }

    func testAFileThatIsNotThereIsNoCameras() throws {
        let dir = try XCTUnwrap(directory)
        for url in [dir.appendingPathComponent("sources.json"), dir.appendingPathComponent("gone/sources.json")] {
            let storage = SourceStorage(fileURL: url)
            XCTAssertEqual(storage.load(), [])
            XCTAssertNil(storage.saveRefusal, url.lastPathComponent)
        }
    }

    /// Reordering the cameras is kept until the app quits when it can't be saved, so the
    /// banner shows. An add, edit or removal is undone instead (see
    /// `SourceChangeWriteFailureTests`), and leaves the banner as it was.
    func testAFailedSaveIsShownUntilASaveWorks() throws {
        let url = try write(savedCamera)
        let manager = SourceManager(storage: SourceStorage(fileURL: url), keychain: InMemoryCredentialStore())
        manager.load()
        try manager.addSource(name: "New", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.2/s")))
        XCTAssertNil(manager.saveProblemMessage)

        try setFolderPermissions(0o555)
        manager.moveSource(from: IndexSet(integer: 1), to: 0)

        XCTAssertTrue(manager.lastSaveFailed)
        XCTAssertNil(manager.saveRefusal, "a failed save refuses nothing")
        XCTAssertEqual(manager.saveProblemMessage, SourceStorage.saveFailureMessage)
        XCTAssertEqual(manager.sources.map(\.name), ["New", "Saved"])
        XCTAssertEqual(try savedNames(in: url), ["Saved", "New"])

        XCTAssertThrowsError(
            try manager.addSource(name: "Refused", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.4/s")))
        )
        XCTAssertEqual(manager.sources.map(\.name), ["New", "Saved"])
        XCTAssertEqual(manager.saveProblemMessage, SourceStorage.saveFailureMessage, "the order is still unsaved")

        try setFolderPermissions(0o755)
        try manager.addSource(name: "Later", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.3/s")))

        XCTAssertFalse(manager.lastSaveFailed)
        XCTAssertNil(manager.saveProblemMessage)
        XCTAssertEqual(try savedNames(in: url), ["New", "Saved", "Later"])
    }

    /// The message says what happened and what it means, and names no file path.
    func testTheSaveFailureMessageStatesTheConsequence() {
        let message = SourceStorage.saveFailureMessage
        XCTAssertTrue(message.contains("couldn’t save your cameras"), message)
        XCTAssertTrue(message.contains("lost when you quit"), message)
        XCTAssertFalse(message.contains("/"), message)
    }
}
