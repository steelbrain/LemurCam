@testable import LemurCam
import XCTest

/// The launch check's result for a camera other than the active one stayed after the
/// user edited that camera: one that failed with "Authentication failed" kept saying
/// so after its password was fixed, until the next launch, and a probe still running
/// when the camera was edited recorded its result for the camera as it was before.
/// An edit now clears that status, and a result about a camera no longer saved as it
/// was probed is dropped.
@MainActor
internal final class BootSanityCheckerEditTests: XCTestCase {
    private var directory: URL?
    private var manager: SourceManager?
    private var savedActiveID: String?

    private static let probedType = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.20:554/stream1"))
    private static let editedType = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.21:554/stream1"))

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = folder
        manager = SourceManager(
            storage: SourceStorage(fileURL: folder.appendingPathComponent("sources.json")),
            keychain: InMemoryCredentialStore()
        )
    }

    override func tearDown() async throws {
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    /// An active camera and another one, as saved when the launch check started.
    private func makeCameras() throws -> (manager: SourceManager, active: CameraSource, other: CameraSource) {
        let sourceManager = try XCTUnwrap(manager)
        try sourceManager.addSource(name: "Front", sourceType: Self.probedType)
        try sourceManager.addSource(name: "Porch", sourceType: Self.probedType)
        let activeID = try XCTUnwrap(sourceManager.activeSourceID)
        let active = try XCTUnwrap(sourceManager.sources.first { $0.id == activeID })
        let other = try XCTUnwrap(sourceManager.sources.first { $0.id != activeID })
        return (sourceManager, active, other)
    }

    /// The reported case: the user fixes what the launch check failed on.
    func testEditingAnInactiveCameraClearsTheLaunchCheckStatus() throws {
        let (sourceManager, _, other) = try makeCameras()
        sourceManager.updateConnectionStatus(for: other.id, status: .error)
        sourceManager.updateErrorMessage(for: other.id, message: "Authentication failed", hostUnreachable: true)

        try sourceManager.updateSource(
            id: other.id, name: "Porch", sourceType: Self.probedType,
            credentials: SourceCredentials(username: "viewer", password: "fixed")
        )

        XCTAssertEqual(sourceManager.connectionStatuses[other.id], .disconnected)
        XCTAssertNil(sourceManager.errorMessages[other.id])
        XCTAssertFalse(sourceManager.unreachableSourceIDs.contains(other.id))
    }

    /// The active camera's status is the stream's, which an edit reconnects.
    func testEditingTheActiveCameraLeavesItsStatusToTheStream() throws {
        let (sourceManager, active, _) = try makeCameras()
        sourceManager.updateConnectionStatus(for: active.id, status: .connected)

        try sourceManager.updateSource(id: active.id, name: "Front", sourceType: Self.editedType, credentials: nil)

        XCTAssertEqual(sourceManager.connectionStatuses[active.id], .connected)
    }

    func testAResultForACameraEditedSinceItsProbeStartedIsDropped() throws {
        let (sourceManager, _, other) = try makeCameras()
        let checker = BootSanityChecker(sourceManager: sourceManager)
        sourceManager.updateConnectionStatus(for: other.id, status: .pending)

        try sourceManager.updateSource(id: other.id, name: "Porch", sourceType: Self.editedType, credentials: nil)
        checker.recordProbeResult(failure: "Authentication failed", for: other)

        XCTAssertEqual(sourceManager.connectionStatuses[other.id], .disconnected)
        XCTAssertNil(sourceManager.errorMessages[other.id])
    }

    /// Only the name changed, but the result is still about the camera as it was.
    func testAResultForARenamedCameraIsDroppedToo() throws {
        let (sourceManager, _, other) = try makeCameras()
        let checker = BootSanityChecker(sourceManager: sourceManager)

        try sourceManager.updateSource(id: other.id, name: "Back Porch", sourceType: Self.probedType, credentials: nil)
        checker.recordProbeResult(failure: nil, for: other)

        XCTAssertEqual(sourceManager.connectionStatuses[other.id], .disconnected)
    }

    func testAResultForACameraSavedAsProbedIsRecorded() throws {
        let (sourceManager, _, other) = try makeCameras()
        let checker = BootSanityChecker(sourceManager: sourceManager)

        checker.recordProbeResult(failure: nil, for: other)

        XCTAssertEqual(sourceManager.connectionStatuses[other.id], .connected)
    }
}
