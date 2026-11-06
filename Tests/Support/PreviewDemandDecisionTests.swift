@testable import LemurCam
import XCTest

/// Pins in-app preview demand: only the popover while it shows the live preview, and
/// the Settings Preview pane, keep the stream connected for the preview. Settings on
/// any other pane must not, so the stream can pause while Settings sits on Logs,
/// Status, or General; nor must the popover while it shows a setup or issue message
/// instead of the preview, which logged into the camera and decoded frames nobody saw.
@MainActor
internal final class PreviewDemandDecisionTests: XCTestCase {
    /// Every camera status; the popover shows the live preview only at `.ready`.
    private static let cameraStatuses: [CameraExtensionStatus] = [
        .unknown, .notInstalled, .installing, .awaitingApproval, .disabled, .needsReboot,
        .needsAppRestart, .ready, .needsRepair, .failed("Activation failed")
    ]

    private func isPreviewNeeded(
        popoverOpen: Bool, cameraStatus: CameraExtensionStatus, settingsPane: SettingsTab?
    ) -> Bool {
        PreviewDemandDecision.isPreviewNeeded(
            popoverOpen: popoverOpen, cameraStatus: cameraStatus, settingsPane: settingsPane
        )
    }

    func testNothingShowingHasNoDemand() {
        for status in Self.cameraStatuses {
            XCTAssertFalse(isPreviewNeeded(popoverOpen: false, cameraStatus: status, settingsPane: nil), "\(status)")
        }
    }

    func testPopoverShowingThePreviewCreatesDemand() {
        XCTAssertTrue(isPreviewNeeded(popoverOpen: true, cameraStatus: .ready, settingsPane: nil))
    }

    /// The reported case: in every other camera state the popover shows a setup or
    /// issue message, so opening it must not connect to the camera.
    func testPopoverShowingASetupOrIssueMessageHasNoDemand() {
        for status in Self.cameraStatuses where status != .ready {
            XCTAssertFalse(isPreviewNeeded(popoverOpen: true, cameraStatus: status, settingsPane: nil), "\(status)")
            for pane in SettingsTab.allCases where pane != .preview {
                XCTAssertFalse(
                    isPreviewNeeded(popoverOpen: true, cameraStatus: status, settingsPane: pane), "\(status), \(pane)"
                )
            }
        }
    }

    /// The camera status changes while the popover stays open (`AppDelegate`
    /// re-evaluates on each change): demand starts when it shows the preview, and
    /// stops when it no longer does.
    func testDemandFollowsTheCameraStatusWhileThePopoverIsOpen() {
        let statuses: [CameraExtensionStatus] = [.installing, .ready, .needsAppRestart, .ready, .disabled]
        let demand = statuses.map { isPreviewNeeded(popoverOpen: true, cameraStatus: $0, settingsPane: nil) }
        XCTAssertEqual(demand, [false, true, false, true, false])
    }

    func testOnlyThePreviewPaneCreatesDemand() {
        for pane in SettingsTab.allCases {
            XCTAssertEqual(
                isPreviewNeeded(popoverOpen: false, cameraStatus: .ready, settingsPane: pane),
                pane == .preview,
                "Unexpected demand for Settings pane \(pane)"
            )
        }
    }

    /// The Settings Preview pane shows the preview whatever the camera status, with
    /// the popover open or not.
    func testPreviewPaneCreatesDemandWhateverTheCameraStatus() {
        for status in Self.cameraStatuses {
            for popoverOpen in [false, true] {
                XCTAssertTrue(
                    isPreviewNeeded(popoverOpen: popoverOpen, cameraStatus: status, settingsPane: .preview),
                    "\(status), popover open: \(popoverOpen)"
                )
            }
        }
    }

    func testPopoverKeepsDemandWhateverSettingsShows() {
        // Handoff: closing Settings (or leaving its Preview pane) while the popover
        // shows the preview must not drop it.
        for pane in SettingsTab.allCases + [nil] {
            XCTAssertTrue(isPreviewNeeded(popoverOpen: true, cameraStatus: .ready, settingsPane: pane))
        }
    }

    func testPreviewPaneKeepsDemandAfterPopoverCloses() {
        // Handoff the other way: the popover closing while Settings shows Preview.
        XCTAssertTrue(isPreviewNeeded(popoverOpen: false, cameraStatus: .ready, settingsPane: .preview))
    }

    // MARK: - What the popover shows

    /// The mapping the popover's view and the demand rule share.
    func testThePopoverShowsThePreviewOnlyWhenTheCameraIsReady() {
        for status in Self.cameraStatuses {
            let state = ExtensionState(cameraStatus: status)
            XCTAssertEqual(state.showsLivePreview, status == .ready, "\(status)")
            XCTAssertEqual(state == .running, status == .ready, "\(status)")
        }
        XCTAssertFalse(ExtensionState(cameraStatus: nil).showsLivePreview, "no setup coordinator")
    }

    // MARK: - Navigation

    func testNavigationReportsOnlyActualPaneChanges() {
        let navigation = SettingsNavigation()
        var changes: [SettingsTab] = []
        navigation.onSelectionChange = { changes.append(navigation.selection) }

        navigation.selection = .preview
        navigation.selection = .preview
        navigation.selection = .logs

        XCTAssertEqual(changes, [.preview, .logs])
    }

    func testNavigationStartsOnSetupAndStatus() {
        XCTAssertEqual(SettingsNavigation().selection, .status)
    }
}
