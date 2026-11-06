@testable import LemurCam
import XCTest

/// Pins in-app preview demand: only the popover and the Settings Preview pane keep
/// the stream connected for the preview. Settings on any other pane must not, so
/// the stream can pause while Settings sits on Logs, Status, or General.
@MainActor
internal final class PreviewDemandDecisionTests: XCTestCase {

    func testNothingShowingHasNoDemand() {
        XCTAssertFalse(PreviewDemandDecision.isPreviewNeeded(popoverOpen: false, settingsPane: nil))
    }

    func testPopoverCreatesDemand() {
        XCTAssertTrue(PreviewDemandDecision.isPreviewNeeded(popoverOpen: true, settingsPane: nil))
    }

    func testOnlyThePreviewPaneCreatesDemand() {
        for pane in SettingsTab.allCases {
            XCTAssertEqual(
                PreviewDemandDecision.isPreviewNeeded(popoverOpen: false, settingsPane: pane),
                pane == .preview,
                "Unexpected demand for Settings pane \(pane)"
            )
        }
    }

    func testPopoverKeepsDemandWhateverSettingsShows() {
        // Handoff: closing Settings (or leaving its Preview pane) while the popover
        // is up must not drop the popover's preview.
        for pane in SettingsTab.allCases + [nil] {
            XCTAssertTrue(PreviewDemandDecision.isPreviewNeeded(popoverOpen: true, settingsPane: pane))
        }
    }

    func testPreviewPaneKeepsDemandAfterPopoverCloses() {
        // Handoff the other way: the popover closing while Settings shows Preview.
        XCTAssertTrue(PreviewDemandDecision.isPreviewNeeded(popoverOpen: false, settingsPane: .preview))
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
