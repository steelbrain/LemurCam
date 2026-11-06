import Foundation
@testable import LemurCam
import XCTest

/// A privileged helper the test answers by hand: every request is recorded, and its
/// reply is sent only when the test calls the recorded completion (or never).
internal final class FakeAudioHelper: AudioHelperClient {
    var state: AudioDeviceInstaller.State = .enabled
    var bundledDriverVersion: String? = "6"
    private(set) var installs: [(MicrophoneOperationResult) -> Void] = []
    private(set) var removals: [(MicrophoneOperationResult) -> Void] = []
    private(set) var checks: [(InstalledDriverCheck) -> Void] = []
    private(set) var registrations = 0
    private(set) var loginItemsOpened = 0

    /// Registering leaves the helper waiting for the user's approval, as it does
    /// the first time.
    func registerHelper() {
        registrations += 1
        state = .requiresApproval
    }

    func openLoginItemsSettings() {
        loginItemsOpened += 1
    }

    func installDriver(completion: @escaping (MicrophoneOperationResult) -> Void) {
        installs.append(completion)
    }

    func uninstallDriver(completion: @escaping (MicrophoneOperationResult) -> Void) {
        removals.append(completion)
    }

    func installedDriver(completion: @escaping (InstalledDriverCheck) -> Void) {
        checks.append(completion)
    }

    /// Answer the latest installed-driver check.
    func answerCheck(_ version: String?, sealed: Bool = true) {
        checks.last?(InstalledDriverCheck(reachable: true, version: version, sealed: sealed))
    }
}

/// A `SetupCoordinator` driven by a `FakeAudioHelper`, with its stale-helper mark in
/// a defaults suite of its own (never the app's), removed by `cleanUp`.
@MainActor
internal final class SetupCoordinatorFixture {
    let helper = FakeAudioHelper()
    let coordinator: SetupCoordinator
    /// The coordinator's stale-helper mark. It is first read when the coordinator
    /// first needs it, so a test can record it before then.
    let staleHelperMarker: StaleHelperMarker
    private let suite = "SetupCoordinatorTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init(operationTimeLimit: Duration = .seconds(30), checkTimeLimit: Duration = .seconds(10)) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        staleHelperMarker = StaleHelperMarker(defaults: defaults, bootTime: { 1 })
        coordinator = SetupCoordinator(
            audioInstaller: helper,
            staleHelperMarker: staleHelperMarker,
            micOperationTimeLimit: operationTimeLimit,
            micCheckTimeLimit: checkTimeLimit
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Bring the microphone to `.ready` with `version` installed (by default the
    /// bundled driver, sealed).
    func makeReady(version: String = "6", sealed: Bool = true) async -> Bool {
        coordinator.refreshMicrophoneStatus()
        helper.answerCheck(version, sealed: sealed)
        return await waitUntil { self.coordinator.micStatus == .ready }
    }

    /// Start an install and let the helper answer it with `result`.
    func install(answering result: MicrophoneOperationResult) async -> Bool {
        coordinator.updateMicrophone()
        guard let reply = helper.installs.last else { return false }
        reply(result)
        return await waitUntil { self.coordinator.micStatus != .installing }
    }
}
