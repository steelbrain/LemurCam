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
    /// Pane to show on first appearance (e.g. jump straight to Cameras).
    var initialTab: SettingsTab = .status

    @State private var selection: SettingsTab?

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail(for: selection ?? initialTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Tuning.settingsWindowWidth, minHeight: Tuning.settingsWindowHeight)
        .onAppear { if selection == nil { selection = initialTab } }
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
