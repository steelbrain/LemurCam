@testable import LemurCam
import XCTest

/// IPCamKit 0.5 takes an `@` after an IPv4 address with a port when no `:` comes before
/// it, as in the stream URIs ONVIF cameras report
/// (`rtsp://192.0.2.5:554/live?password=Adm1n@2024`): such an address isn't read as a
/// user name and the start of a password, as a bracketed IPv6 one wasn't before. The
/// app's copy of the rule (`SourceCredentials.hasAmbiguousUserInfo`) follows it, so the
/// RTSP field takes such a URL and nothing writes its `@` as `%40` any more. Keychain
/// access goes to an in-memory store.
@MainActor
internal final class IPv4AddressAtSignTests: XCTestCase {
    private var directory: URL?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        // `load` may save the active camera in the host app's standard defaults.
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

    /// An IPv4 address with a port as IPCamKit reads one: four numbers of one to three
    /// digits up to 255, and a port of one to five digits. Anything else before the
    /// port is a host name, after which an `@` is still ambiguous.
    func testOnlyAnIPv4AddressWithAPortIsNotReadAsALogin() {
        let address = [
            "rtsp://192.168.1.5:554/live?password=Adm1n@2024", "rtsp://192.168.1.5:554/user=admin&password=p@ss",
            "rtsp://192.168.1.5:554/s?a=b@c@d#e@f", "rtsp://0.0.0.0:1/s@x", "rtsp://255.255.255.255:65535/s@x",
            "rtsp://010.001.000.009:00554/s@x", "rtsp://192.168.1.5:99999/s@x"
        ]
        for url in address {
            XCTAssertFalse(SourceCredentials.hasAmbiguousUserInfo(url), url)
        }
        let notAnAddress = [
            "rtsp://192.168.1.256:554/s@x", "rtsp://192.168.1:554/s@x", "rtsp://1.2.3.4.5:554/s@x",
            "rtsp://192.168.1.5:/s@x", "rtsp://192.168.1.5:123456/s@x", "rtsp://192.168.1.0005:554/s@x",
            "rtsp://192.168..5:554/s@x", "rtsp://192.168.1.5:5a4/s@x", "rtsp://0x7f.0.0.1:554/s@x",
            "rtsp://192.168.1.5:554:1/s@x", "rtsp://cam.local:554/s@x"
        ]
        for url in notAnAddress {
            XCTAssertTrue(SourceCredentials.hasAmbiguousUserInfo(url), url)
        }
    }

    /// Typed into the RTSP field, such a URL is taken and saved as it is.
    func testTheRTSPFieldTakesItAsTyped() {
        let url = "rtsp://192.168.1.5:554/live?password=Adm1n@2024"
        XCTAssertNil(RTSPURLInput.problem(with: url))
        XCTAssertEqual(SourceCredentials.extractingLoginFromRTSPURL(url).url, url)
        XCTAssertNil(SourceCredentials.extractingLoginFromRTSPURL(url).login)
        XCTAssertEqual(SourceCredentials.strippingUserInfo(from: url), url)
    }

    /// Loading leaves such a saved RTSP URL or ONVIF stream URI as it is, and one an
    /// earlier version saved with the `@` written `%40`.
    func testLoadLeavesItAsSaved() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let urls = [
            "rtsp://192.168.1.5:554/user=admin&password=p@ss&channel=1",
            "rtsp://192.168.1.5:554/user=admin&password=p%40ss&channel=1"
        ]
        let sources = urls.flatMap { url in
            [
                CameraSource(name: "DVR", sourceType: .rtsp(RTSPSourceInfo(url: url))),
                CameraSource(name: "Cam", sourceType: .onvif(ONVIFSourceInfo(
                    host: "192.168.1.5", port: 80, streamURI: url
                )))
            ]
        }
        SourceStorage(fileURL: fileURL).save(sources)
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: keychain)

        manager.load()

        XCTAssertEqual(manager.sources.map(\.sourceType), sources.map(\.sourceType))
        XCTAssertTrue(keychain.writes.isEmpty)
    }
}
