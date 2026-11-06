@testable import LemurCam
import XCTest

/// `URLComponents(string:)` percent-encodes a component holding a raw non-ASCII
/// character, and with it the `%` of the escapes already there. A login typed as
/// `rtsp://admin:Grüße%2F1@192.168.1.10/live` was saved with the password `Grüße%2F1`,
/// where IPCamKit reads `Grüße/1`, so every login failed; a path `/caméra%20one` was
/// saved as `/cam%C3%A9ra%2520one`, and a reported ONVIF stream URI was connected to
/// that way too. Camera URLs are now read as IPCamKit reads them, with each non-ASCII
/// character percent-encoded first. That alone left the same double encoding wherever
/// a component also held an ASCII character `URLComponents` encodes (`|`, `^`, `{`, a
/// lone `%`): `admin:£ecret|1@` was saved with the password `%C2%A3ecret|1`, so such
/// characters are now percent-encoded first too, everywhere but the host and port.
/// Keychain access goes to an in-memory store.
@MainActor
internal final class NonASCIIEscapeTests: XCTestCase {
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

    private func makeManager(
        keychain: InMemoryCredentialStore = InMemoryCredentialStore()
    ) throws -> (SourceManager, InMemoryCredentialStore, URL) {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        return (SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: keychain), keychain, fileURL)
    }

    // MARK: - The encoding

    /// IPCamKit's `percentEncodingNonASCII`: the UTF-8 bytes of each non-ASCII scalar,
    /// and nothing else changed.
    func testOnlyNonASCIIScalarsAreEncoded() {
        let encode = URLComponents.percentEncodingNonASCII
        XCTAssertEqual(encode("rtsp://cam/a%20b/é"), "rtsp://cam/a%20b/%C3%A9")
        XCTAssertEqual(encode("rtsp://cam/x?a=%26b&c=é"), "rtsp://cam/x?a=%26b&c=%C3%A9")
        XCTAssertEqual(encode("rtsp://u:p@cam/s?x=%2F#f"), "rtsp://u:p@cam/s?x=%2F#f")
        XCTAssertEqual(encode("e\u{301}😀"), "e%CC%81%F0%9F%98%80")
    }

    /// What `URLComponents` would encode itself is encoded first, but not in the host
    /// and port: an IPv6 host keeps its brackets and zone, and a host it can't read
    /// stays unreadable.
    func testWhatURLComponentsEncodesIsEncodedFirstOutsideTheHost() {
        let encode = URLComponents.percentEncodingForParsing
        XCTAssertEqual(encode("rtsp://u:p|w@[fe80::1%en0]:554/a|b"), "rtsp://u:p%7Cw@[fe80::1%en0]:554/a%7Cb")
        XCTAssertEqual(encode("rtsp://u:a@b:c%@cam/x"), "rtsp://u:a%40b%3Ac%25@cam/x")
        XCTAssertEqual(encode("rtsp://cam/[1]%zz?a=^`\\#f#\"<>"), "rtsp://cam/%5B1%5D%25zz?a=%5E%60%5C#f%23%22%3C%3E")
        XCTAssertEqual(encode("rtsp://cam/s?{x}=%7C%4"), "rtsp://cam/s?%7Bx%7D=%7C%254")
        XCTAssertEqual(encode("rtsp://ca|m/s"), "rtsp://ca|m/s")
        XCTAssertNil(URLComponents(cameraURL: "rtsp://ca|m/s"), "IPCamKit can't read that host either")
        XCTAssertEqual(encode("cam/a|b%zz"), "cam/a|b%zz", "not a URL with a scheme://")
    }

    // MARK: - A URL typed into the form

    func testALoginNextToAnEscapeIsDecodedOnce() {
        let cases: [(url: String, cleaned: String, login: SourceCredentials)] = [
            (
                "rtsp://admin:Grüße%2F1@192.168.1.10/live", "rtsp://192.168.1.10/live",
                .init(username: "admin", password: "Grüße/1")
            ),
            ("rtsp://j%C3%BCrgen:pässw%40rd@cam/x", "rtsp://cam/x", .init(username: "jürgen", password: "pässw@rd")),
            ("rtsp://jürgen%40home:pw@cam/x", "rtsp://cam/x", .init(username: "jürgen@home", password: "pw"))
        ]
        for (url, cleaned, login) in cases {
            let extracted = SourceCredentials.extractingLoginFromRTSPURL(url)
            XCTAssertEqual(extracted.url, cleaned, url)
            XCTAssertEqual(extracted.login?.credentials, login, url)
        }
    }

    /// A component holding an ASCII character `URLComponents` encodes itself had the
    /// escapes in it encoded again, the non-ASCII ones just made among them.
    func testALoginNextToACharacterURLComponentsEncodesIsDecodedOnce() {
        let admin = { (password: String) in SourceCredentials(username: "admin", password: password) }
        let cases: [(url: String, login: SourceCredentials)] = [
            ("rtsp://admin:£ecret|1@192.168.1.10/live", admin("£ecret|1")),
            ("rtsp://admin:Grüße^1@cam/x", admin("Grüße^1")),
            ("rtsp://admin:§pass{1}@cam/x", admin("§pass{1}")),
            ("rtsp://admin:100%Grün@cam/x", admin("100%Grün")),
            ("rtsp://admin:Grüße%2F1|x@cam/x", admin("Grüße/1|x")),
            ("rtsp://jürgen|1:pw@cam/x", SourceCredentials(username: "jürgen|1", password: "pw")),
            ("rtsp://admin:P|ss%40word@cam/x", admin("P|ss@word")),
            ("rtsp://admin:p@ss%21@cam/x", admin("p@ss!")),
            ("rtsp://admin:pa:ss%21@cam/x", admin("pa:ss!")),
            ("rtsp://admin:£|1@[fe80::1%en0]/s", admin("£|1"))
        ]
        for (url, login) in cases {
            XCTAssertNil(RTSPURLInput.problem(with: url), url)
            XCTAssertEqual(SourceCredentials.extractingLoginFromRTSPURL(url).login?.credentials, login, url)
        }
    }

    func testAPathNextToACharacterURLComponentsEncodesKeepsItsEscapes() {
        let cases = [
            "rtsp://admin:pw@cam/caméra|1": "rtsp://cam/cam%C3%A9ra%7C1",
            "rtsp://admin:pw@cam/100%Grün": "rtsp://cam/100%25Gr%C3%BCn",
            "rtsp://admin:pw@cam/s?q=ü^%26": "rtsp://cam/s?q=%C3%BC%5E%26",
            "rtsp://admin:£|1@[fe80::1%en0]:554/caméra": "rtsp://[fe80::1%25en0]:554/cam%C3%A9ra",
            "rtsp://admin:pw@[fe80::1%25en0]/s|1": "rtsp://[fe80::1%25en0]/s%7C1"
        ]
        for (url, cleaned) in cases {
            XCTAssertNil(RTSPURLInput.problem(with: url), url)
            XCTAssertEqual(SourceCredentials.extractingFromRTSPURL(url).url, cleaned, url)
        }
    }

    /// The URL left after the login is taken out keeps its escapes: written with each
    /// non-ASCII character percent-encoded, as IPCamKit sends it.
    func testThePathAndQueryKeepTheirEscapes() {
        let cases = [
            "rtsp://admin:pw@cam/caméra%20one": "rtsp://cam/cam%C3%A9ra%20one",
            "rtsp://admin:pw@cam/s?name=é%26x&b=%2F": "rtsp://cam/s?name=%C3%A9%26x&b=%2F",
            "rtsp://admin:Grüße%2F1@cam/ch%201?q=ü%3D": "rtsp://cam/ch%201?q=%C3%BC%3D"
        ]
        for (url, cleaned) in cases {
            XCTAssertEqual(SourceCredentials.extractingFromRTSPURL(url).url, cleaned, url)
            XCTAssertEqual(DisplayedURL.redacted(url), cleaned, url)
        }
        XCTAssertEqual(
            SourceCredentials.extractingFromRTSPURL("rtsp://cam/caméra%20one").url, "rtsp://cam/caméra%20one",
            "a URL without a login is kept as typed"
        )
    }

    func testAnAddedCameraIsSavedWithTheLoginIPCamKitWouldSend() throws {
        let (manager, keychain, fileURL) = try makeManager()
        try manager.addSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(
            url: "rtsp://admin:Grüße%2F1@192.168.1.10/caméra%20one"
        )))
        let source = try XCTUnwrap(manager.sources.first)

        XCTAssertEqual(source.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.10/cam%C3%A9ra%20one")))
        XCTAssertEqual(keychain.stored[source.id], SourceCredentials(username: "admin", password: "Grüße/1"))
        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains("Grü"), file)
        XCTAssertFalse(file.contains("%2520"), file)
    }

    /// The edit form passes the URL with any login typed into it; that login wins.
    func testAnEditedURLsLoginIsDecodedOnce() throws {
        let (manager, keychain, _) = try makeManager()
        try manager.addSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.10/live")))
        let id = try XCTUnwrap(manager.sources.first?.id)

        let edited = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://admin:pässw%40rd@192.168.1.10/live"))
        try manager.updateSource(id: id, name: "Porch", sourceType: edited, credentials: .remove)

        XCTAssertEqual(keychain.stored[id], SourceCredentials(username: "admin", password: "pässw@rd"))
        XCTAssertEqual(manager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.10/live")))
    }

    /// v1.5 saved a URL with its login. Moving it to the Keychain on load must not
    /// save a wrong password in place of the only right copy.
    func testALoginLeftInASavedURLIsMovedDecodedOnce() throws {
        let (_, keychain, fileURL) = try makeManager()
        let source = CameraSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(
            url: "rtsp://admin:£ecret|1@192.168.1.10/caméra|1"
        )))
        SourceStorage(fileURL: fileURL).save([source])
        let (manager, _, _) = try makeManager(keychain: keychain)

        manager.load()

        XCTAssertEqual(keychain.stored[source.id], SourceCredentials(username: "admin", password: "£ecret|1"))
        XCTAssertEqual(
            manager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.10/cam%C3%A9ra%7C1"))
        )
        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains("ecret"), file)
        XCTAssertFalse(file.contains("%25"), file)
    }

    // MARK: - A stream URI an ONVIF camera reported

    /// What is saved is what is connected to, and the login connected with is the one
    /// IPCamKit would read from the URI.
    func testAReportedURIIsSavedAndConnectedToWithItsEscapes() {
        let admin = { (password: String) in SourceCredentials(username: "admin", password: password) }
        let cases: [(uri: String, url: String, login: SourceCredentials?)] = [
            ("rtsp://admin:pw@192.0.2.5/caméra%20one", "rtsp://192.0.2.5/cam%C3%A9ra%20one", admin("pw")),
            ("rtsp://admin:pässw%40rd@192.0.2.5/s", "rtsp://192.0.2.5/s", admin("pässw@rd")),
            ("rtsp://admin:pä|ss%21@192.0.2.5/s|1", "rtsp://192.0.2.5/s%7C1", admin("pä|ss!")),
            ("rtsp://admin:pw@192.0.2.5/s?ch=é%26x", "rtsp://192.0.2.5/s?ch=%C3%A9%26x", admin("pw")),
            // Split at its last `@`: the rest is kept as reported, and IPCamKit encodes it.
            ("rtsp://admin:Grü#ße%2F1@192.0.2.5/caméra%20one", "rtsp://192.0.2.5/caméra%20one", admin("Grü#ße/1")),
            ("rtsp://192.0.2.5/caméra%20one", "rtsp://192.0.2.5/caméra%20one", nil)
        ]
        for (uri, url, login) in cases {
            let saved = SourceCredentials.strippingUserInfo(fromReportedURI: uri, onvifHost: "192.0.2.5")
            let connected = StreamCoordinator.connectionTarget(
                forResolvedURI: uri, reportedBy: "192.0.2.5", savedCredentials: nil
            )
            XCTAssertEqual(saved, url, uri)
            XCTAssertEqual(connected.url, url, uri)
            XCTAssertEqual(connected.credentials, login, uri)
        }
    }

    func testAnAddedONVIFCameraKeepsTheEscapesOfItsStreamURI() throws {
        let (manager, keychain, _) = try makeManager()
        try manager.addSource(name: "Porch", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.0.2.5", port: 80, selectedProfileToken: "main",
            streamURI: "rtsp://admin:pässw%40rd@192.0.2.5/caméra%20one"
        )))

        guard case .onvif(let info)? = manager.sources.first?.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.streamURI, "rtsp://192.0.2.5/cam%C3%A9ra%20one")
        XCTAssertTrue(keychain.writes.isEmpty, "a camera-reported login is not saved as the source's")
    }

    // MARK: - A stored stream URI moved to a new address

    func testAMovedStreamURIKeepsItsEscapes() throws {
        XCTAssertEqual(
            SourceCredentials.storedStreamURI(
                "rtsp://192.0.2.5/caméra%20one?x=é%26", movedFrom: "192.0.2.5", to: "192.0.2.9"
            ),
            "rtsp://192.0.2.9/cam%C3%A9ra%20one?x=%C3%A9%26"
        )

        let (manager, _, _) = try makeManager()
        let saved = ONVIFSourceInfo(
            host: "192.0.2.5", port: 80, selectedProfileToken: "main", streamURI: "rtsp://192.0.2.5/caméra%20one"
        )
        try manager.addSource(name: "Porch", sourceType: .onvif(saved))
        var moved = saved
        moved.host = "192.0.2.9"
        let id = try XCTUnwrap(manager.sources.first?.id)
        manager.updateONVIFAddress(id: id, from: saved, to: moved)
        XCTAssertEqual(manager.storedONVIFStreamURI(for: id), "rtsp://192.0.2.9/cam%C3%A9ra%20one")
    }

    // MARK: - ONVIF service addresses

    func testAServiceAddressKeepsItsEscapes() {
        XCTAssertEqual(
            ONVIFClient.servicePath(fromXAddr: "http://192.0.2.7/onvif/médiä%20x"), "/onvif/m%C3%A9di%C3%A4%20x"
        )
        XCTAssertEqual(
            ONVIFDiscovery.endpoint(fromXAddrs: "http://192.0.2.7/onvif/dévice%20service", sender: "192.0.2.7")?.url,
            "http://192.0.2.7/onvif/d%C3%A9vice%20service"
        )
    }
}
