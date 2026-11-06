@testable import LemurCam
import XCTest

/// When `sources.json` can't be read, or is damaged and can't be copied aside,
/// `SourceStorage` refuses every save for the session so the file isn't replaced.
/// That used to happen silently: cameras the user added or edited that session were
/// gone after quitting. The refusal is now exposed for Settings → Cameras to show.
/// Adding, editing and removing cameras used to go on meanwhile, changing the
/// Keychain and the saved active camera though the file kept the old cameras: a
/// removed camera came back after a restart without its password. They are now
/// refused with the same message.
@MainActor
internal final class SourceSaveRefusalTests: XCTestCase {
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

    private func makeManager(
        fileURL: URL, keychain: InMemoryCredentialStore = InMemoryCredentialStore()
    ) -> SourceManager {
        SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: keychain)
    }

    private func assertRefused(
        _ refusal: SourceStorage.SaveRefusal, line: UInt = #line, _ change: () throws -> Void
    ) {
        XCTAssertThrowsError(try change(), line: line) { error in
            XCTAssertEqual((error as? SaveRefusedError)?.refusal, refusal, line: line)
            XCTAssertEqual(error.localizedDescription, refusal.message, line: line)
        }
    }

    func testUnreadableFileIsReportedAndRefusesChangesForTheSession() throws {
        let url = try write(savedCamera)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let keychain = InMemoryCredentialStore()
        let manager = makeManager(fileURL: url, keychain: keychain)

        manager.load()

        XCTAssertEqual(manager.saveRefusal, .unreadable)
        XCTAssertEqual(manager.saveProblemMessage, SourceStorage.SaveRefusal.unreadable.message)
        assertRefused(.unreadable) {
            try manager.addSource(
                name: "New", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.3/s")),
                credentials: SourceCredentials(username: "admin", password: "new-pw")
            )
        }
        XCTAssertEqual(manager.sources, [])
        XCTAssertEqual(keychain.writes, [], "no Keychain item without a saved camera")
        XCTAssertEqual(manager.saveRefusal, .unreadable, "the warning stays for the whole session")

        // The no-overwrite guarantee still holds: the file keeps the saved camera.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), savedCamera)
    }

    func testReadableFileReportsNothing() throws {
        let manager = makeManager(fileURL: try write(savedCamera))

        manager.load()

        XCTAssertNil(manager.saveRefusal)
        XCTAssertEqual(manager.sources.map(\.name), ["Saved"])
    }

    func testMissingFileReportsNothing() throws {
        let manager = makeManager(fileURL: try XCTUnwrap(directory).appendingPathComponent("sources.json"))

        manager.load()

        XCTAssertNil(manager.saveRefusal)
    }

    /// A damaged file is moved aside before anything is saved over it. In a folder
    /// that can't be written, neither a move nor a copy works, so saving is refused.
    func testDamagedFileThatCannotBeCopiedIsReported() throws {
        let url = try write("{ this is not valid json")
        let dir = try XCTUnwrap(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let manager = makeManager(fileURL: url)

        manager.load()

        XCTAssertEqual(manager.saveRefusal, .damagedAndNotCopied)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ this is not valid json")
    }

    /// Only one entry could be read and the folder can't be written, so the session
    /// holds that camera while saving is refused. Removing or editing it, or adding
    /// another, changes neither the Keychain nor the list, and picking another active
    /// camera is not saved for the next launch.
    func testRefusedChangesLeaveTheKeychainAndTheSavedActiveCameraAlone() throws {
        let brokenEntry = #"{"id": "22222222-2222-2222-2222-222222222222", "name": "Broken"}"#
        let url = try write(savedCamera.replacingOccurrences(of: "}]", with: "}, \(brokenEntry)]"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: try XCTUnwrap(directory).path)
        let saved = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let keychain = InMemoryCredentialStore()
        try keychain.save(credentials: SourceCredentials(username: "admin", password: "old-pw"), for: saved)
        UserDefaults.standard.set(saved.uuidString, forKey: LemurCamConfig.activeSourceKey)
        let manager = makeManager(fileURL: url, keychain: keychain)
        manager.load()
        XCTAssertEqual(manager.saveRefusal, .damagedAndNotCopied)
        XCTAssertEqual(manager.sources.map(\.id), [saved])
        let writesBefore = keychain.writes

        assertRefused(.damagedAndNotCopied) { try manager.removeSource(id: saved) }
        assertRefused(.damagedAndNotCopied) {
            try manager.updateSource(
                id: saved, name: "Renamed", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.1/s")),
                credentials: SourceCredentials(username: "admin", password: "new-pw")
            )
        }
        assertRefused(.damagedAndNotCopied) {
            try manager.addSource(name: "New", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://admin:pw@192.0.2.3/s")))
        }
        manager.setActiveSource(id: nil)

        XCTAssertEqual(keychain.writes, writesBefore)
        XCTAssertEqual(keychain.stored[saved], SourceCredentials(username: "admin", password: "old-pw"))
        XCTAssertEqual(manager.sources.map(\.name), ["Saved"])
        XCTAssertNil(manager.activeSourceID, "the pick applies to this session")
        XCTAssertEqual(UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey), saved.uuidString)
    }

    /// The message says what happened and what it means for changes, and names no
    /// file path.
    func testMessagesStateTheConsequence() {
        for refusal in [SourceStorage.SaveRefusal.unreadable, .damagedAndNotCopied] {
            XCTAssertTrue(refusal.message.contains("can’t add, edit or remove cameras until it restarts"),
                          refusal.message)
            XCTAssertFalse(refusal.message.contains("/"), refusal.message)
        }
    }
}
