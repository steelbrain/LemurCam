import SwiftUI

/// Sidebar-based settings window. Replaces the old five-tab `TabView`, whose tab
/// bar collapsed into a "»" overflow chevron when the window was too narrow to
/// show every tab. A `NavigationSplitView` sidebar never overflows and leaves
/// room for the guided setup/status page.
internal struct SettingsView: View {
    @Bindable var sourceManager: SourceManager
    let launchAtLoginManager: LaunchAtLoginManager
    var previewStore: PreviewStore?
    var setup: SetupCoordinator
    /// Opens the dedicated guided setup window (owned by `AppDelegate`).
    var openSetup: (() -> Void)?
    /// The selected pane. `AppDelegate` owns it, so it can switch an open window to
    /// a pane (e.g. Cameras) and start or stop preview demand with the Preview pane.
    var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: selection) { tab in
                Label(tab.title, systemImage: tab.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail(for: navigation.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Tuning.settingsWindowWidth, minHeight: Tuning.settingsWindowHeight)
    }

    /// The sidebar can report no selection (Command-click on the selected row);
    /// keep the current pane rather than leave the detail without one.
    private var selection: Binding<SettingsTab?> {
        Binding(
            get: { navigation.selection },
            set: { tab in if let tab { navigation.selection = tab } }
        )
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .status:
            StatusSettingsView(setup: setup, openSetup: openSetup)
        case .cameras:
            SourceListView(sourceManager: sourceManager)
        case .preview:
            PreviewSettingsView(previewStore: previewStore, sourceManager: sourceManager)
        case .general:
            GeneralSettingsView(launchAtLoginManager: launchAtLoginManager)
        case .logs:
            LogsSettingsView()
        }
    }
}

/// The Settings window's selected pane, shared between `SettingsView` and
/// `AppDelegate`.
@MainActor @Observable
internal final class SettingsNavigation {
    var selection: SettingsTab = .status {
        didSet {
            if selection != oldValue { onSelectionChange?() }
        }
    }

    /// Called after the selected pane changes.
    @ObservationIgnored var onSelectionChange: (() -> Void)?
}

/// Pure rule for in-app preview demand. Only the menu bar popover and the Settings
/// Preview pane show the live preview, so only they keep the stream connected for
/// it; Settings on any other pane does not. The popover shows it only while the
/// camera is set up (`ExtensionState.showsLivePreview`). Otherwise it shows a setup or
/// issue message, and connecting for it logged into the camera for frames nobody saw.
internal enum PreviewDemandDecision {
    /// - Parameters:
    ///   - popoverOpen: the menu bar popover is showing.
    ///   - cameraStatus: the camera's setup status, which picks what the popover shows.
    ///   - settingsPane: the pane the Settings window shows, or nil when it's closed.
    static func isPreviewNeeded(
        popoverOpen: Bool, cameraStatus: CameraExtensionStatus, settingsPane: SettingsTab?
    ) -> Bool {
        let popoverShowsPreview = popoverOpen && ExtensionState(cameraStatus: cameraStatus).showsLivePreview
        return popoverShowsPreview || settingsPane == .preview
    }
}

internal enum SettingsTab: String, CaseIterable, Identifiable {
    case status
    case cameras
    case preview
    case general
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Setup & Status"
        case .cameras: return "Cameras"
        case .preview: return "Preview"
        case .general: return "General"
        case .logs: return "Logs"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "checklist"
        case .cameras: return "web.camera"
        case .preview: return "eye"
        case .general: return "gearshape"
        case .logs: return "doc.text"
        }
    }
}
