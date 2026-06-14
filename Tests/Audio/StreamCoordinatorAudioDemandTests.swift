@testable import LemurCam
import XCTest

/// Covers the launch-time recovery of microphone demand. The driver signals consumers
/// with a fire-and-forget Darwin notification, so an app launched while the mic is
/// already in use never receives the `consumerStarted` it missed. Before the fix,
/// `start()` seeded camera demand from persisted state but ignored audio entirely, so
/// the virtual mic stayed silent until the consumer app toggled. The seeding is split
/// into `recoverAudioDemandOnLaunch()` (driven by an injected probe) so it is unit
/// testable without the CoreAudio HAL or the heavyweight `start()` (shm + discovery).
@MainActor
internal final class StreamCoordinatorAudioDemandTests: XCTestCase {

    private func makeManager() -> SourceManager {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        return SourceManager(storage: SourceStorage(fileURL: tempURL), keychain: KeychainService())
    }

    func testRecoverAudioDemandSeedsWhenMicAlreadyRunning() {
        let coordinator = StreamCoordinator(sourceManager: makeManager(), audioConsumerProbe: { true })
        XCTAssertFalse(coordinator.hasDemand, "fresh coordinator should have no demand")

        coordinator.recoverAudioDemandOnLaunch()

        XCTAssertTrue(coordinator.hasDemand, "a mic running at launch must register audio demand")
    }

    func testRecoverAudioDemandStaysClearWhenMicIdle() {
        let coordinator = StreamCoordinator(sourceManager: makeManager(), audioConsumerProbe: { false })

        coordinator.recoverAudioDemandOnLaunch()

        XCTAssertFalse(coordinator.hasDemand, "an idle mic must not bring the pipeline up")
    }
}
