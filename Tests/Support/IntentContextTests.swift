@testable import LemurCam
import XCTest

/// App Intents reach the app through `AppDelegate.shared`, not `NSApp.delegate`
/// (which `@NSApplicationDelegateAdaptor` makes SwiftUI's own object). Pins that the
/// delegate registers itself and that the intents read the right source state.
@MainActor
internal final class IntentContextTests: XCTestCase {
    private var directory: URL?

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    func testAppDelegateRegistersItselfForIntents() {
        // The test host launched through the SwiftUI adaptor, exactly like the app.
        XCTAssertNotNil(AppDelegate.shared)
        XCTAssertNotNil(IntentContext.sourceManager)
    }

    func testEntitiesListEverySource() throws {
        let manager = try loadedManager(with: [CameraSource(name: "Porch", sourceType: Self.rtsp)])
        let entities = CameraEntityQuery.entities(in: manager)
        XCTAssertEqual(entities.map(\.name), ["Porch"])
        XCTAssertEqual(entities.map(\.sourceTypeName), ["RTSP"])
        XCTAssertEqual(entities.map(\.id), manager.sources.map(\.id))
    }

    func testCurrentCameraNameIsTheActiveSource() throws {
        let manager = try loadedManager(with: [
            CameraSource(name: "Porch", sourceType: Self.rtsp),
            CameraSource(name: "Garage", sourceType: Self.rtsp)
        ])
        XCTAssertEqual(GetCurrentCameraIntent.currentCameraName(in: manager), "Porch")
    }

    func testCurrentCameraNameWithoutSourcesIsNone() throws {
        let manager = try loadedManager(with: [])
        XCTAssertEqual(GetCurrentCameraIntent.currentCameraName(in: manager), "None")
    }

    func testConnectionStatusIncludesTheErrorMessage() throws {
        let source = CameraSource(name: "Porch", sourceType: Self.rtsp)
        let manager = try loadedManager(with: [source])
        XCTAssertEqual(GetConnectionStatusIntent.statusText(for: source.id, in: manager), "disconnected")

        manager.updateConnectionStatus(for: source.id, status: .error)
        manager.updateErrorMessage(for: source.id, message: "Timed out")
        XCTAssertEqual(GetConnectionStatusIntent.statusText(for: source.id, in: manager), "error: Timed out")
        XCTAssertEqual(GetConnectionStatusIntent.statusText(for: UUID(), in: manager), "Unknown")
    }

    // MARK: - Helpers

    private static let rtsp = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://camera.invalid/stream"))

    /// A manager loaded from a throwaway sources file. `load()` only reads defaults,
    /// so nothing is written outside the temp directory and no Keychain item is made.
    private func loadedManager(with sources: [CameraSource]) throws -> SourceManager {
        let tempDirectory = try XCTUnwrap(directory)
        let storage = SourceStorage(fileURL: tempDirectory.appendingPathComponent("sources.json"))
        storage.save(sources)
        let manager = SourceManager(storage: storage)
        manager.load()
        return manager
    }
}
