import AppKit

// MARK: - Launch Guards

extension AppDelegate {
    func terminateIfNotInApplications() -> Bool {
        // The unit-test bundle is hosted by the app launched from DerivedData;
        // never terminate the test runner (mirrors terminateIfAlreadyRunning).
        if TestHost.isThisProcess { return false }

        // Enforced in every configuration, including Debug. The CMIO system
        // extension, the SMAppService helper daemon, and the audio HAL driver
        // all require an installed, /Applications-located bundle. Use
        // scripts/dev-run.sh to build, install, and launch from there.
        let bundlePath = Bundle.main.bundlePath
        guard let problem = LaunchLocationDecision.problem(bundlePath: bundlePath) else { return false }

        Log.app.error("App launched from an unsupported location (\(String(describing: problem))): \(bundlePath)")

        let alert = NSAlert()
        alert.messageText = problem.alertTitle
        alert.informativeText = problem.alertMessage
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        // Launch never finished, so `applicationShouldTerminate` quits without prompting.
        NSApp.terminate(nil)
        return true
    }

    func terminateIfAlreadyRunning() -> Bool {
        if TestHost.isThisProcess { return false }

        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        // `isTerminated` plus a `kill(pid, 0)` probe skip an instance that has
        // already exited (e.g. the one that just relaunched us) but that
        // LaunchServices still lists for a moment.
        let instances = runningApps.map { app in
            RunningInstance(
                pid: app.processIdentifier,
                isAlive: !app.isTerminated && kill(app.processIdentifier, 0) == 0
            )
        }
        guard let existingPID = LaunchGuardDecision.existingInstance(
            currentPID: ProcessInfo.processInfo.processIdentifier,
            instances: instances
        ), let existing = runningApps.first(where: { $0.processIdentifier == existingPID }) else {
            return false
        }

        Log.app.info("Another instance already running (pid \(existingPID)), quitting")
        existing.activate(options: .activateAllWindows)
        // Launch never finished, so `applicationShouldTerminate` quits without prompting.
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - Test Host

/// Whether this process is only the unit-test host. App-lifecycle entry points do no
/// real work there: system-extension requests, helper XPC, streaming and the status
/// item can block on OS approval dialogs or IPC and hang a headless test run, and
/// they would write markers into the real app's `UserDefaults.standard` (the host
/// runs under the app's bundle identifier). The logic under test never needs them.
internal enum TestHost {
    /// This process.
    static var isThisProcess: Bool {
        detect(
            environment: ProcessInfo.processInfo.environment,
            testCaseClassLoaded: NSClassFromString("XCTestCase") != nil
        )
    }

    /// `XCTestConfigurationFilePath` is in the host's environment before the process
    /// starts, so it answers even before the test bundle (and `XCTestCase`) loads.
    static func detect(environment: [String: String], testCaseClassLoaded: Bool) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || testCaseClassLoaded
    }
}

/// Why the app refuses to run from its current location.
internal enum LaunchLocationProblem: Equatable {
    /// The bundle lives outside /Applications.
    case notInApplications
    /// macOS App Translocation is running a quarantined copy from a randomized,
    /// read-only path. Happens when the app was moved without Finder (e.g. `mv`) or
    /// opened straight from Downloads or a disk image, even if it sits in /Applications.
    case translocated

    var alertTitle: String {
        switch self {
        case .notInApplications: return "Move to Applications"
        case .translocated: return "Move LemurCam with Finder"
        }
    }

    var alertMessage: String {
        switch self {
        case .notInApplications:
            return """
                LemurCam must be in the Applications folder to install \
                its virtual camera extension.\n\nPlease move LemurCam.app \
                to /Applications and relaunch.
                """
        case .translocated:
            return """
                macOS is running LemurCam from a temporary, read-only copy because \
                the app is still quarantined, so it can't install its virtual \
                camera extension.\n\nIn Finder, move LemurCam.app into the \
                Applications folder. If it's already there, drag it out (for example \
                to the Desktop) and back in. Or remove the quarantine flag in \
                Terminal: xattr -d com.apple.quarantine /Applications/LemurCam.app\n\n\
                Then open LemurCam again.
                """
        }
    }
}

/// Pure launch-location check, kept out of AppKit so it is unit testable.
internal enum LaunchLocationDecision {
    /// Path component macOS uses for App Translocation mounts
    /// (`/private/var/folders/…/AppTranslocation/<UUID>/d/LemurCam.app`). The
    /// `SecTranslocate*` functions that would answer this have no public header in
    /// the macOS SDK, so the documented mount location is the signal.
    static let translocationPathComponent = "/AppTranslocation/"

    static func problem(bundlePath: String) -> LaunchLocationProblem? {
        if bundlePath.hasPrefix("/Applications/") { return nil }
        if bundlePath.contains(translocationPathComponent) { return .translocated }
        return .notInApplications
    }
}

/// Another process running this bundle, as seen at launch.
internal struct RunningInstance: Equatable {
    let pid: pid_t
    /// False once the process has exited, even if LaunchServices still lists it.
    let isAlive: Bool
}

internal enum LaunchGuardDecision {
    /// The live instance (other than this one) the new launch should defer to,
    /// or nil to continue launching.
    static func existingInstance(currentPID: pid_t, instances: [RunningInstance]) -> pid_t? {
        instances.first { $0.pid != currentPID && $0.isAlive }?.pid
    }
}

// MARK: - Quit

/// What `applicationShouldTerminate` should do, as a pure decision.
internal enum TerminationDecision: Equatable {
    /// Quit without asking.
    case terminateNow
    /// Ask before quitting, because an external app is using the virtual camera.
    case confirmCameraInUse

    /// - Parameters:
    ///   - hasFinishedLaunching: false while a launch guard (duplicate instance,
    ///     wrong location) is quitting a launch that never set anything up. A
    ///     prompt there could only be cancelled into a UI-less process.
    ///   - isRelaunching: the user asked to restart; prompting would stall the
    ///     relaunch, which waits for this process to exit.
    ///   - hasExternalConsumers: an external app is streaming from the camera.
    static func evaluate(
        hasFinishedLaunching: Bool,
        isRelaunching: Bool,
        hasExternalConsumers: Bool
    ) -> Self {
        guard hasFinishedLaunching, !isRelaunching, hasExternalConsumers else { return .terminateNow }
        return .confirmCameraInUse
    }
}

// MARK: - Becoming Active

/// Whether `applicationDidBecomeActive` re-checks the camera, the microphone and
/// Launch at Login, as a pure decision.
internal enum ActivationRefreshDecision {
    /// - Parameters:
    ///   - isTestHost: the app is only the unit-test host (`TestHost`), which
    ///     xcodebuild can activate: no camera query or helper XPC there.
    ///   - hasFinishedLaunching: false while launch runs, and in a launch a guard is
    ///     quitting: AppKit can activate the app while the guard's alert ("Move to
    ///     Applications") is up, before the app quits. Launch makes the first checks
    ///     itself, so an activation before it finished has nothing to re-check.
    static func refreshes(isTestHost: Bool, hasFinishedLaunching: Bool) -> Bool {
        !isTestHost && hasFinishedLaunching
    }
}

// MARK: - Restart

/// Builds the detached `/bin/sh` relauncher. It waits for the old process to exit
/// before opening the new instance, so the new one's duplicate-instance guard never
/// sees the old one and quits itself. The wait is bounded: if the old process is
/// still alive after `maxWaitPolls × 0.1 s`, the new instance opens anyway and
/// defers to the old one (no instance is lost).
internal enum RelaunchCommand {
    static let shellPath = "/bin/sh"
    static let openPath = "/usr/bin/open"
    static let maxWaitPolls = 100

    /// Values are passed as positional parameters, never interpolated, so a bundle
    /// path with spaces or quotes can't break the script.
    static let script = """
        pid="$1"; app="$2"; opener="$3"; polls="$4"; i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$polls" ]; do
            sleep 0.1; i=$((i + 1))
        done
        exec "$opener" -n "$app"
        """

    static func arguments(
        waitingFor pid: pid_t,
        appPath: String,
        opener: String = openPath,
        maxPolls: Int = maxWaitPolls
    ) -> [String] {
        ["-c", script, "lemurcam-relaunch", String(pid), appPath, opener, String(maxPolls)]
    }
}

extension AppDelegate {
    /// Restart LemurCam: start the relauncher, then quit without the "Camera in Use"
    /// prompt. If the relauncher can't start, stay running rather than quit with no
    /// new instance coming.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: RelaunchCommand.shellPath)
        task.arguments = RelaunchCommand.arguments(
            waitingFor: ProcessInfo.processInfo.processIdentifier,
            appPath: Bundle.main.bundlePath
        )
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            Log.app.error("Couldn't start the relauncher: \(error.localizedDescription)")
            return
        }
        isRelaunching = true
        NSApp.terminate(nil)
    }
}

extension NSApplication {
    func relaunch() {
        guard let delegate = AppDelegate.shared else {
            Log.app.error("Relaunch requested before the app delegate registered")
            return
        }
        delegate.relaunch()
    }
}
