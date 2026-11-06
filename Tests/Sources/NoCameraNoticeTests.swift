@testable import LemurCam
import XCTest

/// Pins what the popover and the setup wizard's last step say with no camera listed.
/// While saved cameras couldn't be loaded (saving refused for the session), both used
/// to offer adding a camera: the popover said "No Camera Configured", and the wizard's
/// Add Camera marked the step done and opened a Cameras pane where adding is disabled.
@MainActor
internal final class NoCameraNoticeTests: XCTestCase {
    private var directory: URL?

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    func testNoSavedCameraOffersToAddOne() {
        let notice = NoCameraNotice.decide(sourceCount: 0, saveRefusal: nil)
        XCTAssertEqual(notice, .addCamera)
        XCTAssertEqual(notice?.offersAddCamera, true)
    }

    func testSavedCamerasNotLoadedSayWhyAndOfferNoAdd() {
        for refusal in [SourceStorage.SaveRefusal.unreadable, .damagedAndNotCopied] {
            let notice = NoCameraNotice.decide(sourceCount: 0, saveRefusal: refusal)
            XCTAssertEqual(notice, .savedCamerasNotLoaded(refusal), "\(refusal)")
            XCTAssertEqual(notice?.offersAddCamera, false, "\(refusal)")
        }
    }

    func testListedCamerasNeedNoNotice() {
        XCTAssertNil(NoCameraNotice.decide(sourceCount: 1, saveRefusal: nil))
        // A damaged file whose readable entries loaded: those cameras are listed.
        XCTAssertNil(NoCameraNotice.decide(sourceCount: 2, saveRefusal: .damagedAndNotCopied))
    }

    func testAnUnreadableFileLeavesTheManagerShowingWhy() throws {
        let dir = try XCTUnwrap(directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sources.json")
        try Data("[]".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let manager = SourceManager(storage: SourceStorage(fileURL: url), keychain: InMemoryCredentialStore())

        manager.load()

        let notice = NoCameraNotice.decide(sourceCount: manager.sources.count, saveRefusal: manager.saveRefusal)
        XCTAssertEqual(notice, .savedCamerasNotLoaded(.unreadable))
    }
}
