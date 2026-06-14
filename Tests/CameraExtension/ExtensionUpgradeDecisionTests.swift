@testable import LemurCam
import XCTest

/// Pins the camera-extension upgrade classifier. These cases encode the contract
/// the restart/repair UI depends on: a stale extension after an in-place upgrade
/// must be detectable, a genuine reboot requirement must win over an app restart,
/// and a not-yet-reported version must never raise a false "update pending" alarm.
internal final class ExtensionUpgradeDecisionTests: XCTestCase {

    func testMatchingVersionsAreUpToDate() {
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "5", running: "5", rebootFlaggedByOS: false),
            .upToDate
        )
    }

    func testStaleRunningVersionNeedsAppRestart() {
        // Bundled is newer than the version actually running → upgrade pending.
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "5", running: "4", rebootFlaggedByOS: false),
            .appRestartRequired
        )
    }

    func testRunningNewerThanBundledIsUpToDate() {
        // A duplicate/older app copy or a downgrade leaves a newer extension
        // resident. Relaunching this app can't replace it, so this must resolve to
        // up-to-date rather than loop forever asking for a restart.
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "4", running: "5", rebootFlaggedByOS: false),
            .upToDate
        )
        // Even if macOS once flagged a reboot, a newer running version means done.
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "4", running: "5", rebootFlaggedByOS: true),
            .upToDate
        )
    }

    func testDottedVersionsCompareNumerically() {
        // "10" > "9" numerically, not lexically; and equal dotted forms match.
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "9", running: "10", rebootFlaggedByOS: false),
            .upToDate
        )
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "1.2.0", running: "1.2", rebootFlaggedByOS: false),
            .upToDate
        )
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "1.3", running: "1.2", rebootFlaggedByOS: false),
            .appRestartRequired
        )
    }

    func testUnparseableVersionsFallBackToExactMatch() {
        // A non-numeric component can't be ordered: only an exact match is upToDate;
        // anything else is treated as a pending upgrade (the safe, restart-prompting
        // direction), never silently up-to-date.
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "abc", running: "abc", rebootFlaggedByOS: false),
            .upToDate
        )
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "abc", running: "xyz", rebootFlaggedByOS: false),
            .appRestartRequired
        )
    }

    func testCompareVersions() {
        XCTAssertEqual(ExtensionUpgradeDecision.compareVersions("5", "5"), .orderedSame)
        XCTAssertEqual(ExtensionUpgradeDecision.compareVersions("4", "5"), .orderedAscending)
        XCTAssertEqual(ExtensionUpgradeDecision.compareVersions("10", "9"), .orderedDescending)
        XCTAssertEqual(ExtensionUpgradeDecision.compareVersions("1.2", "1.2.0"), .orderedSame)
        XCTAssertNil(ExtensionUpgradeDecision.compareVersions("1.x", "1.2"))
    }

    func testRebootFlagNeedsReboot() {
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "5", running: "4", rebootFlaggedByOS: true),
            .rebootRequired
        )
    }

    func testRebootFlagWithNoRunningVersionStillNeedsReboot() {
        // Extension not running yet but macOS said a reboot finishes the swap.
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "5", running: nil, rebootFlaggedByOS: true),
            .rebootRequired
        )
    }

    func testMatchingVersionsBeatStaleRebootFlag() {
        // The live version already matches what we ship → done, even if an earlier
        // activation once flagged a reboot. Version match takes precedence.
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "5", running: "5", rebootFlaggedByOS: true),
            .upToDate
        )
    }

    func testUnknownRunningVersionDoesNotAlarm() {
        // Pre-handshake build or extension not started: never guess "update pending".
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "5", running: nil, rebootFlaggedByOS: false),
            .unknown
        )
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "5", running: "", rebootFlaggedByOS: false),
            .unknown
        )
    }

    func testMissingBundledVersionIsUnknown() {
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: nil, running: "5", rebootFlaggedByOS: false),
            .unknown
        )
        XCTAssertEqual(
            ExtensionUpgradeDecision.evaluate(bundled: "", running: "5", rebootFlaggedByOS: false),
            .unknown
        )
    }

    // MARK: - Update availability (audio driver parity)

    func testUpdateAvailableOnlyWhenBundledIsNewer() {
        // Bundled strictly newer than installed → an update is genuinely available.
        XCTAssertTrue(ExtensionUpgradeDecision.isUpdateAvailable(installed: "2", bundled: "3"))
        // Same version → no update.
        XCTAssertFalse(ExtensionUpgradeDecision.isUpdateAvailable(installed: "3", bundled: "3"))
        // Installed newer than bundled (duplicate/older app copy) → must NOT show a
        // perpetual "update available".
        XCTAssertFalse(ExtensionUpgradeDecision.isUpdateAvailable(installed: "4", bundled: "3"))
    }

    func testUpdateAvailableUnparseableFallsBackToInequality() {
        XCTAssertFalse(ExtensionUpgradeDecision.isUpdateAvailable(installed: "abc", bundled: "abc"))
        XCTAssertTrue(ExtensionUpgradeDecision.isUpdateAvailable(installed: "abc", bundled: "xyz"))
    }

    // MARK: - Escalation

    func testStuckAppRestartEscalatesToReboot() {
        // We already asked for an app restart for this version and it's still stale
        // → the restart didn't take; a reboot is the reliable fix.
        XCTAssertEqual(
            ExtensionUpgradeDecision.escalateIfStuck(
                base: .appRestartRequired, restartAlreadyTriedForThisVersion: true
            ),
            .rebootRequired
        )
    }

    func testFirstAppRestartDoesNotEscalate() {
        XCTAssertEqual(
            ExtensionUpgradeDecision.escalateIfStuck(
                base: .appRestartRequired, restartAlreadyTriedForThisVersion: false
            ),
            .appRestartRequired
        )
    }

    func testEscalationOnlyAffectsAppRestart() {
        // Every other base state is returned unchanged, even if a restart was tried.
        for base: ExtensionUpgradeState in [.upToDate, .rebootRequired, .unknown] {
            XCTAssertEqual(
                ExtensionUpgradeDecision.escalateIfStuck(
                    base: base, restartAlreadyTriedForThisVersion: true
                ),
                base
            )
        }
    }

    // MARK: - Install classification

    private func classify(total: Int, awaiting: Int, enabled: Int) -> ExtensionInstallClassification {
        ExtensionUpgradeDecision.classifyInstall(
            ExtensionPropertiesSummary(total: total, awaitingApproval: awaiting, enabledActive: enabled)
        )
    }

    func testNoPropertiesIsNotInstalled() {
        XCTAssertEqual(classify(total: 0, awaiting: 0, enabled: 0), .notInstalled)
    }

    func testAwaitingApprovalTakesPriority() {
        // Even with several versions present, an approval gate comes first.
        XCTAssertEqual(classify(total: 1, awaiting: 1, enabled: 0), .awaitingApproval)
        XCTAssertEqual(classify(total: 2, awaiting: 1, enabled: 1), .awaitingApproval)
    }

    func testSingleEnabledIsEnabled() {
        XCTAssertEqual(classify(total: 1, awaiting: 0, enabled: 1), .enabled)
    }

    func testSingleInstalledButDisabled() {
        XCTAssertEqual(classify(total: 1, awaiting: 0, enabled: 0), .disabled)
    }

    func testOneEnabledAmongSeveralIsNormalUpgrade() {
        // Old enabled + new staged for reboot (or + an uninstalling copy): exactly
        // one enabled-active → the normal upgrade path, not a repair.
        XCTAssertEqual(classify(total: 2, awaiting: 0, enabled: 1), .enabled)
        XCTAssertEqual(classify(total: 3, awaiting: 0, enabled: 1), .enabled)
    }

    func testMultipleVersionsWithNoneEnabledNeedsRepair() {
        // Orphaned installs, none active.
        XCTAssertEqual(classify(total: 2, awaiting: 0, enabled: 0), .multipleVersions)
    }

    func testMultipleEnabledVersionsNeedRepair() {
        // Conflicting duplicates both enabled.
        XCTAssertEqual(classify(total: 2, awaiting: 0, enabled: 2), .multipleVersions)
        XCTAssertEqual(classify(total: 3, awaiting: 0, enabled: 2), .multipleVersions)
    }
}
