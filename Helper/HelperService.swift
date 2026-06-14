import Foundation
import OSLog
import Security

/// Root-privileged implementation of the install/uninstall operations. Runs
/// inside the SMAppService-managed daemon, so it can write into the root-owned
/// HAL plug-ins directory and restart coreaudiod. Every privileged action
/// validates its inputs (code-signature pinning) before acting.
internal final class HelperService: NSObject, LemurAudioHelperProtocol {
    private let log = Logger(subsystem: LemurAudioHelper.machServiceName, category: "service")

    /// Hidden staging name inside the (root-owned) HAL directory. Staging there —
    /// rather than validating the client's path in place — closes the
    /// validate-then-copy TOCTOU: the bytes we verify are the bytes we install,
    /// and no non-root process can modify them.
    private var stagingPath: String {
        (LemurAudioHelper.halPluginsDirectory as NSString)
            .appendingPathComponent(".\(LemurAudioHelper.driverBundleName).staging")
    }

    func installDriver(fromPath: String, withReply reply: (Bool, String) -> Void) {
        log.info("installDriver requested")
        guard fromPath.hasSuffix(".driver") else {
            reply(false, "Source is not a .driver bundle")
            return
        }
        if let failure = stageAndValidate(fromPath: fromPath) {
            reply(false, failure)
            return
        }
        do {
            try finalizeInstall()
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            log.error("install move failed: \(error.localizedDescription, privacy: .public)")
            reply(false, "Failed to install driver: \(error.localizedDescription)")
            return
        }
        if let failure = restartCoreAudio() {
            reply(false, "Driver installed but coreaudiod restart failed: \(failure)")
            return
        }
        log.info("driver installed and coreaudiod restarted")
        reply(true, "")
    }

    func uninstallDriver(withReply reply: (Bool, String) -> Void) {
        log.info("uninstallDriver requested")
        let fileManager = FileManager.default
        let destination = LemurAudioHelper.installedDriverPath
        if fileManager.fileExists(atPath: destination) {
            do {
                try fileManager.removeItem(atPath: destination)
            } catch {
                reply(false, "Failed to remove driver: \(error.localizedDescription)")
                return
            }
        }
        if let failure = restartCoreAudio() {
            reply(false, "Driver removed but coreaudiod restart failed: \(failure)")
            return
        }
        reply(true, "")
    }

    func installedVersion(withReply reply: (String?) -> Void) {
        let infoPath = (LemurAudioHelper.installedDriverPath as NSString)
            .appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: infoPath),
              let version = info["CFBundleVersion"] as? String else {
            reply(nil)
            return
        }
        reply(version)
    }

    // MARK: - Private

    /// Copies the client-supplied bundle into the root-owned staging path and
    /// validates the staged copy. Returns nil on success (staging is left in
    /// place for `finalizeInstall`) or an error string (staging is cleaned up).
    private func stageAndValidate(fromPath: String) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                atPath: LemurAudioHelper.halPluginsDirectory,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: stagingPath) {
                try fileManager.removeItem(atPath: stagingPath)
            }
            try fileManager.copyItem(atPath: fromPath, toPath: stagingPath)
        } catch {
            try? fileManager.removeItem(atPath: stagingPath)
            log.error("staging copy failed: \(error.localizedDescription, privacy: .public)")
            return "Failed to stage driver: \(error.localizedDescription)"
        }
        if let failure = validateSignature(path: stagingPath, requirement: LemurAudioHelper.driverRequirement) {
            try? fileManager.removeItem(atPath: stagingPath)
            log.error("driver signature invalid: \(failure, privacy: .public)")
            return "Driver signature validation failed: \(failure)"
        }
        return nil
    }

    /// Atomically replaces the installed driver with the validated staged bundle
    /// (rename within the same root-owned directory).
    private func finalizeInstall() throws {
        let fileManager = FileManager.default
        let destination = LemurAudioHelper.installedDriverPath
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        try fileManager.moveItem(atPath: stagingPath, toPath: destination)
    }

    /// Returns nil if `path` satisfies `requirement`, otherwise an error string.
    /// Checks all architectures and nested code so a fat bundle cannot smuggle an
    /// unsigned slice past validation.
    private func validateSignature(path: String, requirement: String) -> String? {
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode))
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return "SecStaticCodeCreateWithPath failed (\(createStatus))"
        }
        var requirementRef: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirement as CFString, [], &requirementRef)
        guard reqStatus == errSecSuccess, let parsedRequirement = requirementRef else {
            return "SecRequirementCreateWithString failed (\(reqStatus))"
        }
        let checkStatus = SecStaticCodeCheckValidity(code, flags, parsedRequirement)
        guard checkStatus == errSecSuccess else {
            return "code requirement not satisfied (\(checkStatus))"
        }
        return nil
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
