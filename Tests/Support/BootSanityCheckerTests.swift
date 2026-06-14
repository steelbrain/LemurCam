@testable import LemurCam
import XCTest

/// Covers the synchronous decision `BootSanityChecker.run()` makes before its
/// async reachability probes: it marks every non-active source `.pending` and
/// leaves the active source alone, and does nothing when there are no other
/// sources. The probe outcomes themselves are network-dependent and out of scope;
/// unreachable loopback hosts keep the spawned probe task short-lived.
@MainActor
internal final class BootSanityCheckerTests: XCTestCase {
    private var tempURL: URL?
    private var manager: SourceManager?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        guard let tempURL else { return }
        manager = SourceManager(storage: SourceStorage(fileURL: tempURL), keychain: KeychainService())
    }

    override func tearDown() async throws {
        if let sourceManager = manager {
            for source in sourceManager.sources { try? KeychainService().delete(for: source.id) }
        }
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
        try await super.tearDown()
    }

    /// Loopback port 1 refuses immediately, so the probe task fails fast.
    private func unreachableONVIF() -> SourceType {
        .onvif(ONVIFSourceInfo(host: "127.0.0.1", port: 1))
    }

    func testMarksNonActiveSourcesPendingAndLeavesActiveAlone() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "active", sourceType: unreachableONVIF())
        sourceManager.addSource(name: "other", sourceType: unreachableONVIF())
        let activeID = try XCTUnwrap(sourceManager.activeSourceID)
        let otherID = try XCTUnwrap(sourceManager.sources.first { $0.id != activeID }).id

        BootSanityChecker(sourceManager: sourceManager).run()

        // The pending marking is synchronous, before the async probe task can run.
        XCTAssertEqual(sourceManager.connectionStatuses[otherID], .pending)
        XCTAssertEqual(sourceManager.connectionStatuses[activeID], .disconnected)
    }

    func testNoOtherSourcesLeavesActiveUntouched() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "only", sourceType: unreachableONVIF())
        let activeID = try XCTUnwrap(sourceManager.activeSourceID)

        BootSanityChecker(sourceManager: sourceManager).run()

        XCTAssertEqual(sourceManager.connectionStatuses[activeID], .disconnected)
    }
}
