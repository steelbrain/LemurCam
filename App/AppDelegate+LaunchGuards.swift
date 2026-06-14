import AppKit

// MARK: - Launch Guards

extension AppDelegate {
    func terminateIfNotInApplications() -> Bool {
        // The unit-test bundle is hosted by the app launched from DerivedData;
        // never terminate the test runner (mirrors terminateIfAlreadyRunning).
        if NSClassFromString("XCTestCase") != nil { return false }

        // Enforced in every configuration, including Debug. The CMIO system
        // extension, the SMAppService helper daemon, and the audio HAL driver
        // all require an installed, /Applications-located bundle. Use
        // scripts/dev-run.sh to build, install, and launch from there.
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasPrefix("/Applications/") { return false }

        Log.app.error("App launched from outside /Applications: \(bundlePath)")

        let alert = NSAlert()
        alert.messageText = "Move to Applications"
        alert.informativeText = """
            LemurCam must be in the Applications folder to install \
            its virtual camera extension.\n\nPlease move LemurCam.app \
            to /Applications and relaunch.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }

    func terminateIfAlreadyRunning() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return false }

        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        guard let existing = runningApps.first(where: { $0 != .current }) else {
            return false
        }

        Log.app.info("Another instance already running (pid \(existing.processIdentifier)), quitting")
        existing.activate(options: .activateAllWindows)
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - Restart

extension NSApplication {
    func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        terminate(nil)
    }
}
