import ServiceManagement

/// The login-item calls `LaunchAtLoginManager` makes. The app passes
/// `SMAppService.mainApp`; tests pass a fake, so they never touch the real login item.
internal protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

@Observable
internal final class LaunchAtLoginManager {
    private(set) var isEnabled = false

    private let service: any LoginItemService

    init(service: any LoginItemService = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    /// Re-read whether LemurCam opens at login. The user can remove it in System
    /// Settings → General → Login Items without the app hearing of it, so this runs
    /// whenever the app becomes active and before the menu or the General pane shows
    /// the setting.
    func refresh() {
        let enabled = service.status == .enabled
        guard enabled != isEnabled else { return }
        isEnabled = enabled
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            isEnabled = enabled
        } catch {
            // Show what the service reports now rather than what was asked for. Turning
            // off a login item already gone (kSMErrorJobNotFound) leaves it off, as asked.
            refresh()
            if isEnabled == enabled {
                Log.app.info("Launch at login was already \(enabled ? "on" : "off")")
            } else {
                Log.app.error("Launch at login toggle failed: \(error)")
            }
        }
    }
}
