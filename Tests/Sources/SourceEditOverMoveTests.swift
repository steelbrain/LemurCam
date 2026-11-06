@testable import LemurCam
import XCTest

/// The edit form works on a copy of the camera taken when it opened. When WS-Discovery
/// found an ONVIF camera at another address meanwhile and saved it, saving the form
/// (a rename, or just Return) wrote back the address the camera left and the stored
/// stream URI naming it, so the saved login went to whatever device answers there. An
/// edit that left the address as it was loaded now keeps the one saved since; an
/// address the user edited still wins. Credentials go to an in-memory store.
@MainActor
internal final class SourceEditOverMoveTests: XCTestCase {
    private static let loaded = ONVIFSourceInfo(
        deviceUUID: "2b9c0b1e-0000-4000-8000-00000000c0de", host: "192.168.1.20", port: 80,
        selectedProfileToken: "main", streamURI: "rtsp://192.168.1.20:554/main", serialNumber: "SN-1"
    )
    private static let login = SourceCredentials(username: "viewer", password: "pw")

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

    private func fileURL() throws -> URL {
        try XCTUnwrap(directory).appendingPathComponent("sources.json")
    }

    /// A manager holding the camera as `loaded`, which WS-Discovery then moves to `moved`.
    private func managerWithMovedCamera(
        moved: ONVIFSourceInfo
    ) throws -> (manager: SourceManager, id: UUID, keychain: InMemoryCredentialStore) {
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: SourceStorage(fileURL: try fileURL()), keychain: keychain)
        try manager.addSource(name: "Porch", sourceType: .onvif(Self.loaded), credentials: Self.login)
        let id = try XCTUnwrap(manager.sources.first?.id)
        manager.updateONVIFAddress(id: id, from: Self.loaded, to: moved)
        return (manager, id, keychain)
    }

    private static func movedTo(
        host: String = "192.168.1.31", port: Int = 80, useHTTPS: Bool = false
    ) -> ONVIFSourceInfo {
        var moved = loaded
        moved.host = host
        moved.port = port
        moved.useHTTPS = useHTTPS
        return moved
    }

    private func savedInfo(_ manager: SourceManager) -> ONVIFSourceInfo? {
        guard case .onvif(let info)? = manager.sources.first?.sourceType else { return nil }
        return info
    }

    private func reloadedInfo() throws -> ONVIFSourceInfo? {
        let storage = SourceStorage(fileURL: try fileURL())
        let reloaded = SourceManager(storage: storage, keychain: InMemoryCredentialStore())
        reloaded.load()
        return savedInfo(reloaded)
    }

    // MARK: - Through the manager

    /// The reported case: the form was opened before the move and only renames the camera.
    func testARenameFromAFormOpenedBeforeAMoveKeepsTheMove() throws {
        let (manager, id, keychain) = try managerWithMovedCamera(moved: Self.movedTo())
        let movedInfo = try XCTUnwrap(savedInfo(manager))
        XCTAssertEqual(movedInfo.streamURI, "rtsp://192.168.1.31:554/main")

        try manager.updateSource(
            id: id, name: "Front Porch", sourceType: .onvif(Self.loaded), credentials: .keep,
            editedFrom: .onvif(Self.loaded)
        )

        XCTAssertEqual(manager.sources.first?.name, "Front Porch")
        XCTAssertEqual(savedInfo(manager), movedInfo, "nothing about the camera's address may go back")
        XCTAssertEqual(try reloadedInfo(), movedInfo, "the file keeps the move too")
        XCTAssertEqual(keychain.stored[id], Self.login)
    }

    /// A move to another port, or from HTTP to HTTPS, is kept as well.
    func testAMoveOfThePortOrHTTPSIsKept() throws {
        let moved = Self.movedTo(host: "192.168.1.20", port: 8443, useHTTPS: true)
        let (manager, id, _) = try managerWithMovedCamera(moved: moved)

        try manager.updateSource(
            id: id, name: "Porch", sourceType: .onvif(Self.loaded), credentials: .keep, editedFrom: .onvif(Self.loaded)
        )

        let saved = try XCTUnwrap(savedInfo(manager))
        XCTAssertEqual(saved.port, 8443)
        XCTAssertTrue(saved.useHTTPS)
        XCTAssertEqual(saved.streamURI, Self.loaded.streamURI, "the URI names the same host")
    }

    /// The user edited the address (and fetched profiles there, as Save requires):
    /// their address wins over the move.
    func testAnAddressTheUserEditedWins() throws {
        let (manager, id, _) = try managerWithMovedCamera(moved: Self.movedTo())
        var edited = Self.loaded
        edited.host = "192.168.1.40"
        edited.streamURI = "rtsp://192.168.1.40:554/main"

        try manager.updateSource(
            id: id, name: "Porch", sourceType: .onvif(edited), credentials: .keep, editedFrom: .onvif(Self.loaded)
        )

        XCTAssertEqual(savedInfo(manager), edited)
        XCTAssertEqual(try reloadedInfo(), edited)
    }

    /// Another profile picked at the loaded address: the address and the stream URI
    /// follow the move, and the profile picked is saved.
    func testAnotherProfilePickedKeepsTheMoveAndMovesItsURI() throws {
        let (manager, id, _) = try managerWithMovedCamera(moved: Self.movedTo())
        var edited = Self.loaded
        edited.selectedProfileToken = "sub"
        edited.streamURI = "rtsp://192.168.1.20:554/sub"

        try manager.updateSource(
            id: id, name: "Porch", sourceType: .onvif(edited), credentials: .keep, editedFrom: .onvif(Self.loaded)
        )

        let saved = try XCTUnwrap(savedInfo(manager))
        XCTAssertEqual(saved.host, "192.168.1.31")
        XCTAssertEqual(saved.selectedProfileToken, "sub")
        XCTAssertEqual(saved.streamURI, "rtsp://192.168.1.31:554/sub")
    }

    /// With no move since the form opened, the edit is saved as it is.
    func testAnEditWithoutAMoveIsSavedAsItIs() throws {
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: SourceStorage(fileURL: try fileURL()), keychain: keychain)
        try manager.addSource(name: "Porch", sourceType: .onvif(Self.loaded), credentials: Self.login)
        let id = try XCTUnwrap(manager.sources.first?.id)
        var edited = Self.loaded
        edited.selectedProfileToken = "sub"
        edited.streamURI = "rtsp://192.168.1.20:554/sub"

        try manager.updateSource(
            id: id, name: "Porch", sourceType: .onvif(edited), credentials: .keep, editedFrom: .onvif(Self.loaded)
        )

        XCTAssertEqual(savedInfo(manager), edited)
    }

    // MARK: - The rule

    func testOnlyAnONVIFEditThatKeptTheLoadedAddressGivesWay() {
        let asLoaded = SourceType.onvif(Self.loaded)
        let moved = SourceType.onvif(Self.movedTo())
        XCTAssertEqual(asLoaded.keepingMove(savedSince: asLoaded, now: moved), moved)
        XCTAssertEqual(asLoaded.keepingMove(savedSince: asLoaded, now: asLoaded), asLoaded, "no move")

        let rtsp = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.20/s"))
        XCTAssertEqual(rtsp.keepingMove(savedSince: asLoaded, now: moved), rtsp, "a camera changed to RTSP")
        XCTAssertEqual(asLoaded.keepingMove(savedSince: rtsp, now: moved), asLoaded)

        // An address the user edited stays.
        let elsewhere = SourceType.onvif(Self.movedTo(host: "192.168.1.50"))
        XCTAssertEqual(elsewhere.keepingMove(savedSince: asLoaded, now: moved), elsewhere)
    }

    /// The form's own details stay: the move changes only the address and its URI.
    func testTheFormsOtherDetailsStay() {
        var edited = Self.loaded
        edited.deviceUUID = "urn:uuid:5f0c3a2e-0000-4000-8000-000000000001"
        edited.serialNumber = "SN-2"
        var moved = Self.movedTo()
        moved.streamURI = nil

        guard case .onvif(let kept) = SourceType.onvif(edited).keepingMove(
            savedSince: .onvif(Self.loaded), now: .onvif(moved)
        ) else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(kept.host, "192.168.1.31")
        XCTAssertNil(kept.streamURI, "the URI the move dropped stays dropped")
        XCTAssertEqual(kept.deviceUUID, edited.deviceUUID)
        XCTAssertEqual(kept.serialNumber, "SN-2")
        XCTAssertEqual(kept.selectedProfileToken, "main")
    }
}
