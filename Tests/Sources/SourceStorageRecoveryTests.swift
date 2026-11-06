@testable import LemurCam
import XCTest

/// `SourceStorage.load()` used to decode the whole file in one go and return [] on
/// any error; the next save then overwrote the file, losing every camera and
/// orphaning their Keychain items. Entries are now decoded one by one, and a damaged
/// file is kept next to the original instead of being overwritten.
internal final class SourceStorageRecoveryTests: XCTestCase {
    private var directory: URL?

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func write(_ json: String) throws -> URL {
        let dir = try XCTUnwrap(directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sources.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func preservedCopies() throws -> [URL] {
        let dir = try XCTUnwrap(directory)
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("sources.json.corrupt-") }
    }

    private let goodEntry = """
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Good",
         "createdAt": "2026-01-02T03:04:05Z", "updatedAt": "2026-01-02T03:04:05Z",
         "sourceType": {"rtsp": {"_0": {"url": "rtsp://192.0.2.1/s"}}}}
        """

    /// The ONVIF entry is missing its required port.
    private let badEntry = """
        {"id": "22222222-2222-2222-2222-222222222222", "name": "Bad",
         "createdAt": "2026-01-02T03:04:05Z", "updatedAt": "2026-01-02T03:04:05Z",
         "sourceType": {"onvif": {"_0": {"host": "192.0.2.2"}}}}
        """

    func testOneDamagedEntryKeepsTheOthersAndACopy() throws {
        let original = "[\(goodEntry), \(badEntry)]"
        let url = try write(original)

        let loaded = SourceStorage(fileURL: url).load()

        XCTAssertEqual(loaded.map(\.name), ["Good"])
        let copies = try preservedCopies()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(copies.first), encoding: .utf8), original)
        // The original stays in place too; only the next save rewrites it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUndecodableFileIsMovedAsideNotOverwritten() throws {
        let original = "{ this is not valid json"
        let url = try write(original)
        let storage = SourceStorage(fileURL: url)

        XCTAssertTrue(storage.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // The app's next save writes a fresh file; the damaged one survives beside it.
        storage.save([CameraSource(name: "New", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.3/s")))])
        XCTAssertEqual(storage.load().map(\.name), ["New"])
        let copies = try preservedCopies()
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(copies.first), encoding: .utf8), original)
    }

    /// A file that can't be read (here: no read permission) took the decode-failure
    /// path and was moved aside as damaged, and the next save wrote a file without the
    /// user's cameras. It is now left in place, and nothing is saved over it.
    func testUnreadableFileIsLeftInPlaceAndNotOverwritten() throws {
        let original = "[\(goodEntry)]"
        let url = try write(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let storage = SourceStorage(fileURL: url)

        XCTAssertTrue(storage.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try preservedCopies().isEmpty, "an unreadable file is not damaged")

        storage.save([CameraSource(name: "New", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.3/s")))])

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        XCTAssertEqual(SourceStorage(fileURL: url).load().map(\.name), ["Good"])
    }

    func testIntactFileLeavesNoCopy() throws {
        let url = try write("[\(goodEntry)]")
        XCTAssertEqual(SourceStorage(fileURL: url).load().count, 1)
        XCTAssertTrue(try preservedCopies().isEmpty)
    }

    /// Log lines describe where decoding failed by key name, never by value.
    func testFailureDescriptionOmitsValues() {
        let json = """
            [{"id": "not-a-uuid-secret", "name": "X", "createdAt": "2026-01-02T03:04:05Z",
              "updatedAt": "2026-01-02T03:04:05Z", "sourceType": {"rtsp": {"_0": {"url": 42}}}}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            _ = try decoder.decode([CameraSource].self, from: Data(json.utf8))
            XCTFail("expected a decoding error")
        } catch {
            let description = SourceStorage.describe(error)
            XCTAssertFalse(description.contains("secret"), description)
            XCTAssertFalse(description.contains("42"), description)
            XCTAssertTrue(description.contains("[0]"), description)
        }
    }
}
