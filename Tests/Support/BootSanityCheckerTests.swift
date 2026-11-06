@testable import LemurCam
import os
import XCTest

/// Stands in for IPCamKit's `RTSPClientSession`: `start()` ignores task
/// cancellation and returns only once `stop()` is called.
private final class StubRTSPSession: Sendable {
    private struct State {
        var stopped = false
        var stops = 0
        var waiter: CheckedContinuation<Void, Never>?
    }

    struct Stopped: Error {}

    private let state = OSAllocatedUnfairLock(initialState: State())

    var stopCount: Int { state.withLock { $0.stops } }

    func start() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.stopped { return true }
                state.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        throw Stopped()
    }

    func stop() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.stopped = true
            state.stops += 1
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

/// Covers the synchronous decision `BootSanityChecker.run()` makes before its
/// async reachability probes (it marks every non-active source `.pending`, leaves
/// the active source alone, and does nothing when there are no other sources) and
/// what a finished probe records. Probes only reach loopback hosts that refuse at
/// once, which keeps the spawned probe task short-lived.
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
        manager = SourceManager(storage: SourceStorage(fileURL: tempURL), keychain: InMemoryCredentialStore())
    }

    override func tearDown() async throws {
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
        try sourceManager.addSource(name: "active", sourceType: unreachableONVIF())
        try sourceManager.addSource(name: "other", sourceType: unreachableONVIF())
        let activeID = try XCTUnwrap(sourceManager.activeSourceID)
        let otherID = try XCTUnwrap(sourceManager.sources.first { $0.id != activeID }).id

        BootSanityChecker(sourceManager: sourceManager).run()

        // The pending marking is synchronous, before the async probe task can run.
        XCTAssertEqual(sourceManager.connectionStatuses[otherID], .pending)
        XCTAssertEqual(sourceManager.connectionStatuses[activeID], .disconnected)
    }

    func testNoOtherSourcesLeavesActiveUntouched() throws {
        let sourceManager = try XCTUnwrap(manager)
        try sourceManager.addSource(name: "only", sourceType: unreachableONVIF())
        let activeID = try XCTUnwrap(sourceManager.activeSourceID)

        BootSanityChecker(sourceManager: sourceManager).run()

        XCTAssertEqual(sourceManager.connectionStatuses[activeID], .disconnected)
    }

    // MARK: - Late probe results

    func testProbeResultIsRecordedForInactiveSource() throws {
        let sourceManager = try XCTUnwrap(manager)
        try sourceManager.addSource(name: "active", sourceType: unreachableONVIF())
        try sourceManager.addSource(name: "other", sourceType: unreachableONVIF())
        let other = try XCTUnwrap(sourceManager.sources.last)
        let otherID = other.id
        let checker = BootSanityChecker(sourceManager: sourceManager)

        checker.recordProbeResult(failure: "Authentication failed", for: other)

        XCTAssertEqual(sourceManager.connectionStatuses[otherID], .error)
        XCTAssertEqual(sourceManager.errorMessages[otherID], "Authentication failed")
    }

    /// A probe that finishes after the user switched to that camera must not
    /// overwrite the live stream's status with "Unreachable".
    func testLateResultDoesNotOverwriteNowActiveSource() throws {
        let sourceManager = try XCTUnwrap(manager)
        try sourceManager.addSource(name: "active", sourceType: unreachableONVIF())
        try sourceManager.addSource(name: "other", sourceType: unreachableONVIF())
        let other = try XCTUnwrap(sourceManager.sources.last)
        let otherID = other.id
        let checker = BootSanityChecker(sourceManager: sourceManager)
        sourceManager.setActiveSource(id: otherID)
        sourceManager.updateConnectionStatus(for: otherID, status: .connected)

        checker.recordProbeResult(failure: "Authentication failed", for: other)

        XCTAssertEqual(sourceManager.connectionStatuses[otherID], .connected)
        XCTAssertNil(sourceManager.errorMessages[otherID])
    }

    func testLateResultForDeletedSourceIsDropped() throws {
        let sourceManager = try XCTUnwrap(manager)
        try sourceManager.addSource(name: "active", sourceType: unreachableONVIF())
        try sourceManager.addSource(name: "other", sourceType: unreachableONVIF())
        let other = try XCTUnwrap(sourceManager.sources.last)
        let otherID = other.id
        let checker = BootSanityChecker(sourceManager: sourceManager)
        try sourceManager.removeSource(id: otherID)

        checker.recordProbeResult(failure: nil, for: other)

        XCTAssertNil(sourceManager.connectionStatuses[otherID])
    }

    // MARK: - Failure messages

    /// Every failed probe used to read "Unreachable", even a camera that answered and
    /// rejected the saved login. The message now says what went wrong.
    func testProbeFailureMessageNamesTheCause() {
        struct UndescribedError: Error {}
        XCTAssertEqual(BootSanityChecker.probeFailureMessage(for: ONVIFError.authenticationFailed),
                       "Authentication failed")
        XCTAssertEqual(BootSanityChecker.probeFailureMessage(for: ONVIFError.soapFault("Sender not Authorized")),
                       "ONVIF error: Sender not Authorized")
        let timedOut = ONVIFError.timedOut.localizedDescription
        XCTAssertEqual(BootSanityChecker.probeFailureMessage(for: ONVIFError.timedOut), timedOut)
        XCTAssertEqual(BootSanityChecker.probeFailureMessage(for: RTSPStreamPipeline.TimeoutError()), timedOut)
        XCTAssertEqual(BootSanityChecker.probeFailureMessage(for: UndescribedError()), "Unreachable")
    }

    /// End to end on loopback: the probe of a camera that refuses the connection
    /// records the ONVIF network error, not a generic word.
    func testFailedProbeRecordsItsError() async throws {
        let sourceManager = try XCTUnwrap(manager)
        try sourceManager.addSource(name: "active", sourceType: unreachableONVIF())
        try sourceManager.addSource(name: "other", sourceType: unreachableONVIF())
        let otherID = try XCTUnwrap(sourceManager.sources.last).id

        BootSanityChecker(sourceManager: sourceManager).run()

        let failed = await waitUntil(timeout: 10) { sourceManager.connectionStatuses[otherID] == .error }
        XCTAssertTrue(failed)
        let message = try XCTUnwrap(sourceManager.errorMessages[otherID])
        XCTAssertTrue(message.hasPrefix("Network error:"), message)
    }

    // MARK: - RTSP probe timeout

    /// IPCamKit's `start()` ignores cancellation, so the probe's timeout used to wait
    /// for it to finish on its own. The timeout now stops the session.
    func testRTSPProbeTimeoutStopsAStartThatIgnoresCancellation() async {
        let session = StubRTSPSession()
        // Safety net so a regression fails on the elapsed-time check instead of hanging.
        let safety = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            session.stop()
        }
        defer { safety.cancel() }

        let started = Date()
        do {
            try await BootSanityChecker.probeRTSPStart(
                timeoutNs: 50_000_000, start: { try await session.start() }, stop: { session.stop() }
            )
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is RTSPStreamPipeline.TimeoutError, "\(error)")
            XCTAssertEqual(BootSanityChecker.probeFailureMessage(for: error), ONVIFError.timedOut.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// A session that started is stopped again; the probe only checks reachability.
    func testRTSPProbeStopsTheSessionAfterAStart() async throws {
        let session = StubRTSPSession()
        try await BootSanityChecker.probeRTSPStart(timeoutNs: 2_000_000_000, start: {}, stop: { session.stop() })
        XCTAssertEqual(session.stopCount, 1)
    }
}
