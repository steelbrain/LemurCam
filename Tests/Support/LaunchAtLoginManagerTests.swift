@testable import LemurCam
import ServiceManagement
import XCTest

/// Pins that Launch at Login follows the login item's real state. It was read only
/// when the app started, so after the user removed LemurCam in System Settings →
/// Login Items the setting still showed on, and turning it off called `unregister()`,
/// which threw (kSMErrorJobNotFound) and left the toggle snapping back on. Driven by
/// a fake service: these tests never touch the real login item.
internal final class LaunchAtLoginManagerTests: XCTestCase {
    private let jobNotFound = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorJobNotFound))

    func testStartsFromTheServicesState() {
        XCTAssertTrue(LaunchAtLoginManager(service: FakeLoginItemService(status: .enabled)).isEnabled)
        for status: SMAppService.Status in [.notRegistered, .requiresApproval, .notFound] {
            XCTAssertFalse(LaunchAtLoginManager(service: FakeLoginItemService(status: status)).isEnabled, "\(status)")
        }
    }

    func testRefreshSeesTheLoginItemRemovedInSystemSettings() {
        let service = FakeLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(service: service)

        service.status = .notRegistered
        manager.refresh()

        XCTAssertFalse(manager.isEnabled)
    }

    func testTurningOffALoginItemRemovedOutsideTheAppCallsNothing() {
        let service = FakeLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(service: service)
        service.status = .notRegistered

        manager.setEnabled(false)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testUnregisteringALoginItemAlreadyGoneLeavesItOff() {
        // Removed in System Settings between the read and the call: unregister throws.
        let service = FakeLoginItemService(status: .enabled)
        service.unregisterError = jobNotFound
        service.statusAfterFailure = .notRegistered
        let manager = LaunchAtLoginManager(service: service)

        manager.setEnabled(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(manager.isEnabled)
    }

    func testAFailedUnregisterShowsTheStateTheServiceReports() {
        let service = FakeLoginItemService(status: .enabled)
        service.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorInternalFailure))
        let manager = LaunchAtLoginManager(service: service)

        manager.setEnabled(false)

        XCTAssertTrue(manager.isEnabled, "still registered, so still on")
    }

    func testAFailedRegisterShowsTheStateTheServiceReports() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = NSError(domain: "SMAppServiceErrorDomain", code: Int(kSMErrorLaunchDeniedByUser))
        let manager = LaunchAtLoginManager(service: service)

        manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)

        // Registered meanwhile (by System Settings, say): the failure shows it on.
        service.statusAfterFailure = .enabled
        let other = LaunchAtLoginManager(service: service)
        other.setEnabled(true)
        XCTAssertTrue(other.isEnabled)
    }

    func testTogglingCallsTheServiceOnce() {
        let service = FakeLoginItemService(status: .notRegistered)
        let manager = LaunchAtLoginManager(service: service)

        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        manager.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)

        manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        manager.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
    }
}

/// Stands in for `SMAppService.mainApp`.
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    /// The status a failed call leaves; nil leaves it as it was.
    var statusAfterFailure: SMAppService.Status?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        try finish(succeeding: .enabled, unless: registerError)
    }

    func unregister() throws {
        unregisterCalls += 1
        try finish(succeeding: .notRegistered, unless: unregisterError)
    }

    private func finish(succeeding success: SMAppService.Status, unless error: (any Error)?) throws {
        guard let error else {
            status = success
            return
        }
        if let statusAfterFailure { status = statusAfterFailure }
        throw error
    }
}
