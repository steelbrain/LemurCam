import AppIntents

internal struct LemurCamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SwitchCameraIntent(),
            phrases: [
                "Switch camera in \(.applicationName)",
                "Switch \(.applicationName) camera"
            ],
            shortTitle: "Switch Camera",
            systemImageName: "arrow.triangle.2.circlepath.camera"
        )
        AppShortcut(
            intent: GetCurrentCameraIntent(),
            phrases: [
                "Get current camera in \(.applicationName)",
                "What camera is \(.applicationName) using"
            ],
            shortTitle: "Get Current Camera",
            systemImageName: "web.camera"
        )
        AppShortcut(
            intent: GetConnectionStatusIntent(),
            phrases: [
                "Get connection status in \(.applicationName)",
                "Is \(.applicationName) camera connected"
            ],
            shortTitle: "Get Connection Status",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
    }
}
