import Foundation
import OSLog

/// Root-privileged implementation of the install/uninstall operations. Runs
/// inside the SMAppService-managed daemon, so it can write into the root-owned
/// HAL plug-ins directory and restart coreaudiod. The file work is done by
/// `DriverInstaller` (shared with the unit tests): the driver is copied into
/// private, per-request staging, sealed to root:wheel, signature-checked, and
/// renamed into place.
internal final class HelperService: NSObject, LemurAudioHelperProtocol {
    /// Every privileged operation runs here, one at a time across all connections:
    /// installs and removals share the HAL directory and the coreaudiod restart.
    private static let operations = DispatchQueue(label: "cam.lemur.app.helper.operations")

    private let log = Logger(subsystem: LemurAudioHelper.machServiceName, category: "service")

    private let installer = DriverInstaller(
        pluginsDirectory: LemurAudioHelper.halPluginsDirectory,
        bundleName: LemurAudioHelper.driverBundleName,
        owner: .root,
        validateSignature: { path in
            LemurAudioHelper.validateSignature(path: path, requirement: LemurAudioHelper.driverRequirement)
        }
    )

    func installDriver(fromPath: String, withReply reply: (Bool, String) -> Void) {
        log.info("installDriver requested")
        guard fromPath.hasSuffix(".driver") else {
            reply(false, "Source is not a .driver bundle")
            return
        }
        let (success, message) = Self.operations.sync { install(from: fromPath) }
        reply(success, message)
    }

    func uninstallDriver(withReply reply: (Bool, String) -> Void) {
        log.info("uninstallDriver requested")
        let (success, message) = Self.operations.sync { () -> (Bool, String) in
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
        let version = Self.operations.sync { installer.installedVersion() }
        reply(version)
    }

    // MARK: - Private

    private func install(from source: String) -> (Bool, String) {
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

    /// Restarts coreaudiod so a freshly installed/removed HAL plug-in is picked up.
    /// `launchctl kickstart -k` reports an unreliable exit code (often non-zero even
    /// when the restart took), so its outcome is ignored; success is decided by
    /// re-querying the service afterwards. Returns nil if coreaudiod is running, or
    /// an error string otherwise.
    private func restartCoreAudio() -> String? {
        runLaunchctl(["kickstart", "-k", LemurAudioHelper.coreAudioServiceTarget])
        let statusCode = runLaunchctl(["print", LemurAudioHelper.coreAudioServiceTarget])
        return LemurAudioHelper.coreAudioRestartResult(statusCheckExitCode: statusCode)
    }

    /// Runs a `launchctl` invocation, discarding its output, and returns its exit
    /// status (or -1 if the process could not be launched).
    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
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
