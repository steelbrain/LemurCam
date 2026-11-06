import AppKit

extension SetupCoordinator {
    /// Open System Settings to the Login Items & Extensions pane, scrolled to the
    /// Extensions list. On macOS 15+ this lands on the modern "By App" view, where
    /// LemurCam appears as a Media Extension — rather than the legacy by-category
    /// Extensions pane (com.apple.ExtensionsPreferences), which buried it under a
    /// category heading.
    func openCameraSystemSettings() {
        let settingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems"
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
