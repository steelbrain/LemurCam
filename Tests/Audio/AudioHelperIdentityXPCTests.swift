import Foundation
@testable import LemurCam
import os
import XCTest

/// The installed-driver check tells a current helper from one built before
/// `helperBuild` existed (v1.5 and before) by whether it answers that message. These
/// run the app's check over real NSXPC connections to helpers exported in this
/// process by an anonymous listener: the one exported here as from v1.5 has only the
/// selectors v1.5 had. Nothing is installed and no privileged helper is contacted.
internal final class AudioHelperIdentityXPCTests: XCTestCase {
    private var listener: NSXPCListener?
    /// Held here: a listener does not retain what accepts its connections.
    private var exporter: Exporter?

    override func setUp() {
        super.setUp()
        listener = nil
        exporter = nil
    }

    override func tearDown() {
        listener?.invalidate()
        listener = nil
        exporter = nil
        super.tearDown()
    }

    /// Runs the check against `exported`, served through `interface`.
    private func check(
        against exported: NSObject?, interface: Protocol, limit: TimeInterval = 0.5
    ) async -> InstalledDriverCheck? {
        let exporting = Exporter(interface: NSXPCInterface(with: interface), exported: exported)
        let anonymous = NSXPCListener.anonymous()
        anonymous.delegate = exporting
        anonymous.resume()
        listener = anonymous
        exporter = exporting

        let result = OSAllocatedUnfairLock<InstalledDriverCheck?>(initialState: nil)
        let answered = expectation(description: "the check completes")
        AudioDeviceInstaller.checkInstalledDriver(
            on: NSXPCConnection(listenerEndpoint: anonymous.endpoint), identifyWithin: limit, sealed: { true },
            completion: { check in
                result.withLock { $0 = check }
                answered.fulfill()
            }
        )
        await fulfillment(of: [answered], timeout: 10)
        // A second completion would over-fulfill the expectation and fail the test.
        try? await Task.sleep(nanoseconds: UInt64((limit + 0.3) * 1_000_000_000))
        return result.withLock { $0 }
    }

    func testACurrentHelperIsIdentified() async {
        let check = await check(against: CurrentHelper(), interface: LemurAudioHelperProtocol.self)

        XCTAssertEqual(check, InstalledDriverCheck(reachable: true, version: "6", sealed: true, helper: .current))
    }

    /// A helper from v1.5 lacks `helperBuild`: its NSXPC drops the message and ends
    /// the connection. The version it answered first still counts.
    func testAHelperWithoutHelperBuildIsStale() async {
        let check = await check(against: LegacyHelper(), interface: LegacyAudioHelperProtocol.self)

        XCTAssertEqual(check, InstalledDriverCheck(reachable: true, version: "6", sealed: true, helper: .stale))
    }

    /// One that never answers it is stale once the time limit passes.
    func testAHelperThatNeverAnswersHelperBuildIsStale() async {
        let check = await check(against: SilentHelper(), interface: LemurAudioHelperProtocol.self)

        XCTAssertEqual(check, InstalledDriverCheck(reachable: true, version: nil, sealed: false, helper: .stale))
    }

    func testAHelperThatCantBeReachedIsUnreachable() async {
        let check = await check(against: nil, interface: LemurAudioHelperProtocol.self)

        XCTAssertEqual(check, .unreachable)
    }
}

/// The selectors every helper up to v1.5 exports: no `helperBuild`.
@objc private protocol LegacyAudioHelperProtocol {
    func installDriver(fromPath: String, withReply reply: @escaping (Bool, String) -> Void)
    func uninstallDriver(withReply reply: @escaping (Bool, String) -> Void)
    func installedVersion(withReply reply: @escaping (String?) -> Void)
}

private final class LegacyHelper: NSObject, LegacyAudioHelperProtocol {
    func installDriver(fromPath _: String, withReply reply: (Bool, String) -> Void) {
        reply(false, "not in tests")
    }

    func uninstallDriver(withReply reply: (Bool, String) -> Void) {
        reply(false, "not in tests")
    }

    func installedVersion(withReply reply: (String?) -> Void) {
        reply("6")
    }
}

private class CurrentHelper: NSObject, LemurAudioHelperProtocol {
    func installDriver(fromPath _: String, withReply reply: (Bool, String) -> Void) {
        reply(false, "not in tests")
    }

    func uninstallDriver(withReply reply: (Bool, String) -> Void) {
        reply(false, "not in tests")
    }

    func installedVersion(withReply reply: (String?) -> Void) {
        reply("6")
    }

    func helperBuild(withReply reply: (String) -> Void) {
        reply(LemurAudioHelper.helperBuild)
    }
}

/// Reports no driver, and never answers `helperBuild`.
private final class SilentHelper: CurrentHelper {
    override func installedVersion(withReply reply: (String?) -> Void) {
        reply(nil)
    }

    override func helperBuild(withReply _: (String) -> Void) {}
}

/// Exports `exported` on every connection, or refuses them all when it is nil.
private final class Exporter: NSObject, NSXPCListenerDelegate {
    private let interface: NSXPCInterface
    private let exported: NSObject?

    init(interface: NSXPCInterface, exported: NSObject?) {
        self.interface = interface
        self.exported = exported
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let exported else { return false }
        connection.exportedInterface = interface
        connection.exportedObject = exported
        connection.resume()
        return true
    }
}
