import Darwin
import Foundation

/// Restarts coreaudiod (so a newly installed or removed HAL plug-in is picked up)
/// and checks that a new instance came up, deciding with
/// `LemurAudioHelper.coreAudioRestartResult`. The process runner, PID lookup, and
/// wait are injected so the decision loop is unit-testable without launchd.
internal struct CoreAudioRestarter {
    /// Runs `launchctl` with the arguments; returns its exit status, or -1 if it
    /// could not be launched.
    let runLaunchctl: ([String]) -> Int32
    /// PID of the running system coreaudiod, nil if there is none.
    let coreAudioPID: () -> pid_t?
    /// Waits between checks for the new instance.
    let pause: () -> Void
    /// How many times to look for the new instance before giving up.
    let maxChecks: Int

    /// Returns nil once a new coreaudiod is running, otherwise the reason it is not.
    func restart() -> String? {
        let before = coreAudioPID()
        let status = runLaunchctl(["kickstart", "-k", LemurAudioHelper.coreAudioServiceTarget])
        var after = coreAudioPID()
        if status != -1 {
            var checks = 1
            // The old instance may still be exiting, and launchd relaunches it after.
            while checks < maxChecks, after == nil || after == before {
                pause()
                after = coreAudioPID()
                checks += 1
            }
        }
        return LemurAudioHelper.coreAudioRestartResult(kickstartStatus: status, pidBefore: before, pidAfter: after)
    }
}

/// Finds the system coreaudiod process.
internal enum CoreAudioProcess {
    /// PID of the live coreaudiod: a process named `coreaudiod`, running as
    /// `_coreaudiod`, whose parent is launchd. Matching all three keeps a same-named
    /// process another user starts from passing for a restart.
    static func currentPID() -> pid_t? {
        guard let account = getpwnam("_coreaudiod") else { return nil }
        let uid = account.pointee.pw_uid
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return nil }
        let live = processes.prefix(size / stride).first { process in
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
            }
            return name == "coreaudiod" && process.kp_eproc.e_ppid == 1
                && process.kp_eproc.e_ucred.cr_uid == uid && Int32(process.kp_proc.p_stat) != SZOMB
        }
        return live?.kp_proc.p_pid
    }
}
