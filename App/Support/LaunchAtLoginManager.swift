import os
import ServiceManagement

@Observable
internal final class LaunchAtLoginManager {
    private(set) var isEnabled = false

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
        } catch {
            Log.app.error("Launch at login toggle failed: \(error)")
        }
    }
}
