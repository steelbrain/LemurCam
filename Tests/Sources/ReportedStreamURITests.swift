@testable import LemurCam
import XCTest

/// A stream URI an ONVIF camera reports is saved as the camera's fallback without
/// the login some cameras put in its userinfo. It used to be cut at its last `@`
/// whenever that `@` came after the host, so a login in the query
/// (`?password=Adm1n@2024`) was saved as `rtsp://2024`. It is now cut there only when
/// `URLComponents` can't read it, or when the host after that `@` is the camera's.
/// All Keychain access goes to an in-memory store.
@MainActor
internal final class ReportedStreamURITests: XCTestCase {
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
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func splits(_ uri: String, host: String = "192.0.2.5") -> Bool {
        SourceCredentials.splitsAtLastAt(reportedURI: uri, onvifHost: host)
    }

    // MARK: - The split rule

    func testAURIURLComponentsCantReadIsSplit() {
        XCTAssertTrue(splits("rtsp://user:p#ss@192.0.2.5/s"))
        XCTAssertTrue(splits("rtsp://user:p?ss@192.0.2.5/s", host: "192.0.2.9"))
    }

    func testAReadableURIIsSplitOnlyWhenTheHostAfterTheLastAtSignIsTheCamera() {
        XCTAssertTrue(splits("rtsp://admin:1234/5@192.0.2.5/s"))
        XCTAssertTrue(splits("rtsp://admin:1234/5@Cam.local/s", host: "cam.LOCAL"))
        XCTAssertFalse(splits("rtsp://admin:1234/5@192.0.2.5/s", host: "192.0.2.6"))
        for uri in [
            "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024",
            "rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1_stream=0.sdp",
            "rtsp://admin:pw@192.0.2.5:554/live?password=Adm1n@2024"
        ] {
            XCTAssertFalse(splits(uri), uri)
        }
    }

    func testAURIWithoutAnAmbiguousAtSignIsNotSplit() {
        for uri in ["rtsp://admin:pw@192.0.2.5/s", "rtsp://192.0.2.5/s", "rtsp://192.0.2.5/live?password=x"] {
            XCTAssertFalse(splits(uri), uri)
        }
    }

    func testStrippingAReportedURI() {
        let cases = [
            "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024":
                "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024",
            "rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1":
                "rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1",
            "rtsp://admin:pw@192.0.2.5:554/live?password=Adm1n@2024": "rtsp://192.0.2.5:554/live?password=Adm1n@2024",
            "rtsp://admin:1234/5@192.0.2.5/s": "rtsp://192.0.2.5/s",
            "rtsp://user:p#ss@192.0.2.5/s": "rtsp://192.0.2.5/s",
            "rtsp://admin:pw@192.0.2.5/s": "rtsp://192.0.2.5/s"
        ]
        for (uri, stripped) in cases {
            let saved = SourceCredentials.strippingUserInfo(fromReportedURI: uri, onvifHost: "192.0.2.5")
            XCTAssertEqual(saved, stripped, uri)
        }
    }

    // MARK: - Saving

    /// Adds an ONVIF camera at 192.0.2.5 that reported `reported`, and returns the
    /// stream URI it was saved with and the saved file.
    private func save(reported: String) throws -> (uri: String?, file: String) {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        try? FileManager.default.removeItem(at: fileURL)
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: InMemoryCredentialStore())
        try manager.addSource(name: "Porch", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.0.2.5", port: 80, selectedProfileToken: "main", streamURI: reported
        )))
        guard case .onvif(let info) = try XCTUnwrap(manager.sources.first).sourceType else {
            XCTFail("expected ONVIF")
            return (nil, "")
        }
        return (info.streamURI, try String(contentsOf: fileURL, encoding: .utf8))
    }

    func testALoginInTheQueryIsSavedWithTheAddress() throws {
        let reported = "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024"
        XCTAssertEqual(try save(reported: reported).uri, reported)
    }

    func testALoginInTheUserInfoIsDroppedBeforeSaving() throws {
        let readable = try save(reported: "rtsp://admin:s3cret@192.0.2.5:554/live?password=Adm1n@2024")
        XCTAssertEqual(readable.uri, "rtsp://192.0.2.5:554/live?password=Adm1n@2024")
        XCTAssertFalse(readable.file.contains("s3cret"))

        let rawSlash = try save(reported: "rtsp://admin:12/34@192.0.2.5/main")
        XCTAssertEqual(rawSlash.uri, "rtsp://192.0.2.5/main")
        XCTAssertFalse(rawSlash.file.contains("12/34"))
    }
}
