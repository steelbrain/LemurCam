import Foundation
import OSLog

/// Root-privileged implementation of the install/uninstall operations. Runs
/// inside the SMAppService-managed daemon, so it can write into the root-owned
/// HAL plug-ins directory and restart coreaudiod. The file work is done by
/// `DriverInstaller` (shared with the unit tests): the driver is copied from the
/// calling app's own bundle into private, per-request staging, sealed to
/// root:wheel, signature-checked, downgrade-checked, and renamed into place.
internal final class HelperService: NSObject, LemurAudioHelperProtocol {
    /// Every privileged operation runs here, one at a time across all connections:
    /// installs and removals share the HAL directory and the coreaudiod restart.
    private static let operations = DispatchQueue(label: "cam.lemur.app.helper.operations")

    private let log = Logger(subsystem: LemurAudioHelper.machServiceName, category: "service")
    /// Held busy while an operation runs, so the helper never exits in the middle
    /// of one, even if the client has disconnected.
    private let idle: HelperIdleExit

    private let installer = DriverInstaller(
        pluginsDirectory: LemurAudioHelper.halPluginsDirectory,
        bundleName: LemurAudioHelper.driverBundleName,
        owner: .root,
        validateSignature: { path in
            LemurAudioHelper.validateSignature(path: path, requirement: LemurAudioHelper.driverRequirement)
        }
    )

    init(idle: HelperIdleExit) {
        self.idle = idle
    }

    func installDriver(fromPath _: String, withReply reply: (Bool, String) -> Void) {
        log.info("installDriver requested")
        // Only valid on the thread delivering the message, so read it before the hop.
        let connection = NSXPCConnection.current()
        let (success, message) = perform { install(for: connection) }
        reply(success, message)
    }

    func uninstallDriver(withReply reply: (Bool, String) -> Void) {
        log.info("uninstallDriver requested")
        let (success, message) = perform { () -> (Bool, String) in
            do {
                try installer.uninstall()
            } catch {
                log.error("uninstall failed: \(Self.describe(error), privacy: .public)")
                return (false, "Failed to remove driver: \(Self.describe(error))")
            }
            if let failure = restartCoreAudio() {
                return (false, "Driver removed but coreaudiod restart failed: \(failure)")
            }
            return (true, "")
        }
        reply(success, message)
    }

    func installedVersion(withReply reply: (String?) -> Void) {
        let version = perform { installer.installedVersion() }
        reply(version)
    }

    // MARK: - Private

    /// Run `work` on the operations queue, holding the helper up while it runs.
    private func perform<T>(_ work: () -> T) -> T {
        let activity = idle.begin()
        defer { activity?.end() }
        return Self.operations.sync(execute: work)
    }

    private func install(for connection: NSXPCConnection?) -> (Bool, String) {
        guard let connection else { return (false, "No calling app connection") }
        let source: String
        switch CallerCode.appBundlePath(of: connection) {
        case .success(let appBundle):
            source = LemurAudioHelper.bundledDriverPath(inAppBundle: appBundle)
        case .failure(let failure):
            log.error("caller lookup failed: \(failure.description, privacy: .public)")
            return (false, failure.description)
        }
        do {
            try installer.install(from: source)
        } catch {
            log.error("install failed: \(Self.describe(error), privacy: .public)")
            return (false, "Failed to install driver: \(Self.describe(error))")
        }
        if let failure = restartCoreAudio() {
            return (false, "Driver installed but coreaudiod restart failed: \(failure)")
        }
        log.info("driver installed and coreaudiod restarted")
        return (true, "")
    }

    private static func describe(_ error: Error) -> String {
        (error as? DriverBundleFiles.Failure)?.description ?? error.localizedDescription
    }

    /// Restarts coreaudiod so a freshly installed/removed HAL plug-in is picked up,
    /// waiting up to 5 s for the new instance. Returns nil once it is running.
    private func restartCoreAudio() -> String? {
        let restarter = CoreAudioRestarter(
            runLaunchctl: { [log] arguments in Self.runLaunchctl(arguments, log: log) },
            coreAudioPID: CoreAudioProcess.currentPID,
            pause: { usleep(200_000) },
            maxChecks: 25
        )
        let failure = restarter.restart()
        if let failure {
            log.error("coreaudiod restart failed: \(failure, privacy: .public)")
        }
        return failure
    }

    /// Runs a `launchctl` invocation, discarding its output, and returns its exit
    /// status (or -1 if the process could not be launched).
    private static func runLaunchctl(_ arguments: [String], log: Logger) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            log.error("launchctl failed to run: \(error.localizedDescription, privacy: .public)")
            return -1
        }
        return task.terminationStatus
    }
}
