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

    func registerHelper() {}
    func openLoginItemsSettings() {}

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
    private let suite = "SetupCoordinatorTests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init(operationTimeLimit: Duration = .seconds(30), checkTimeLimit: Duration = .seconds(10)) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        coordinator = SetupCoordinator(
            audioInstaller: helper,
            staleHelperMarker: StaleHelperMarker(defaults: defaults, bootTime: { 1 }),
            micOperationTimeLimit: operationTimeLimit,
            micCheckTimeLimit: checkTimeLimit
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Bring the microphone to `.ready` with the bundled driver installed and sealed.
    func makeReady() async -> Bool {
        coordinator.refreshMicrophoneStatus()
        helper.answerCheck("6")
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
