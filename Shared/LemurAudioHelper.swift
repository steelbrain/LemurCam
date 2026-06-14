import Foundation

/// XPC contract and shared constants for the privileged helper that installs the
/// virtual-microphone AudioServerPlugIn into the root-owned HAL plug-ins
/// directory. Compiled into BOTH the app (the XPC client) and the Helper daemon
/// (the XPC server). The helper runs as root via SMAppService; the app talks to
/// it over an NSXPCConnection pinned to each side's code-signing requirement.
@objc internal protocol LemurAudioHelperProtocol {
    /// Install (or replace) the AudioServerPlugIn `.driver` bundle found at
    /// `fromPath` into the HAL plug-ins directory and restart coreaudiod. The
    /// helper validates `fromPath`'s code signature against `driverRequirement`
    /// before copying. Reply: (success, message) — message is empty on success
    /// or a human-readable error otherwise.
    func installDriver(fromPath: String, withReply reply: @escaping (Bool, String) -> Void)

    /// Remove the installed driver and restart coreaudiod. Reply as above.
    func uninstallDriver(withReply reply: @escaping (Bool, String) -> Void)

    /// CFBundleVersion of the currently installed driver, or nil if not installed.
    func installedVersion(withReply reply: @escaping (String?) -> Void)
}

/// Identifiers, install locations, and code-signing requirements shared by the
/// app and the helper. Requirements pin the bundle identifier, the Apple anchor,
/// and the team OU (which works for both Developer ID and development signing).
internal enum LemurAudioHelper {
    /// launchd Label and Mach service name for the helper daemon. Must match the
    /// `Label` / `MachServices` keys in the LaunchDaemon plist.
    static let machServiceName = "cam.lemur.app.helper"

    /// Basename passed to `SMAppService.daemon(plistName:)`. The plist must live
    /// at `Contents/Library/LaunchDaemons/<this>` inside the app bundle.
    static let daemonPlistName = "cam.lemur.app.helper.plist"

    /// File name of the installed driver bundle.
    static let driverBundleName = "LemurCamAudio.driver"

    /// System HAL plug-ins directory (root-owned, scanned by coreaudiod).
    static let halPluginsDirectory = "/Library/Audio/Plug-Ins/HAL"

    /// Absolute path of the installed driver bundle.
    static var installedDriverPath: String {
        (halPluginsDirectory as NSString).appendingPathComponent(driverBundleName)
    }

    private static let teamIdentifier = "2KG9772KH6"

    /// Requirement the helper enforces on incoming connections (the app).
    static let appRequirement =
        "identifier \"cam.lemur.app\" and anchor apple generic and " +
        "certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Requirement the app enforces on the helper it connects to.
    static let helperRequirement =
        "identifier \"\(machServiceName)\" and anchor apple generic and " +
        "certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Requirement the helper enforces on the driver bundle before installing it.
    static let driverRequirement =
        "identifier \"cam.lemur.app.audio\" and anchor apple generic and " +
        "certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// launchd service target for the system audio daemon, used to restart it and to
    /// re-query whether it came back.
    static let coreAudioServiceTarget = "system/com.apple.audio.coreaudiod"

    /// Decides whether the coreaudiod restart succeeded from the *status check* exit
    /// code, NOT from the restart command's own exit code. `launchctl kickstart -k`
    /// frequently reports a non-zero status even when the restart took, which is what
    /// produced the spurious "install/remove failed" reports. So the caller ignores
    /// kickstart's outcome and instead re-queries the service: `launchctl print`
    /// exits 0 when coreaudiod is known to launchd and running, non-zero only when it
    /// genuinely isn't — the meaningful end state to report.
    static func coreAudioRestartResult(statusCheckExitCode: Int32) -> String? {
        statusCheckExitCode == 0
            ? nil
            : "coreaudiod is not running (launchctl print exited with status \(statusCheckExitCode))"
    }
}
