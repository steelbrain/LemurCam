import Foundation

/// Remembers, until the Mac restarts, that the audio helper serving the app is a
/// stale one: an install through it left a copy not sealed to root, or it
/// identified itself as one (`AudioHelperIdentity.stale`), and only a restart
/// replaces it (`MicrophoneStatus.needsReboot`). Kept for the app's session alone,
/// the mark was gone after relaunching the app, which then offered Update again, and
/// that install through the same helper cut audio again for nothing. A check
/// answered by a current helper clears it, as the stale one can stop before then.
///
/// Stored in the app's own defaults (not the app group) with the boot time it was
/// seen in, and counted only while the Mac's boot time is still that one. Injected
/// defaults and boot time keep it testable, as `SetupStateStore` is.
internal struct StaleHelperMarker {
    private let defaults: UserDefaults
    private let bootTime: () -> Int?
    private static let key = "LemurCam.staleAudioHelperBootTime"

    /// - Parameters:
    ///   - defaults: where the mark is kept.
    ///   - bootTime: when the Mac last started, nil when unknown (see `BootTime`).
    init(defaults: UserDefaults, bootTime: @escaping () -> Int? = BootTime.current) {
        self.defaults = defaults
        self.bootTime = bootTime
    }

    /// Whether a stale helper was seen since the Mac last started. The boot time must
    /// match exactly, so a mark from before a restart never counts. When the boot
    /// time can't be read, or reads differently within one boot, the mark lapses
    /// early, which only brings back the Update offer: the lesser harm.
    var isSet: Bool {
        guard let current = bootTime(), let seenIn = defaults.object(forKey: Self.key) as? Int else {
            return false
        }
        return seenIn == current
    }

    /// Record that a stale helper is serving the app, until the Mac restarts.
    func record() {
        guard let current = bootTime() else { return }
        defaults.set(current, forKey: Self.key)
    }

    /// A current helper serves the app now: the stale one stopped without a restart
    /// (turned off in Login Items, crashed, or killed), and launchd started the
    /// current one. The mark kept every check of that boot asking for a restart.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// Records or clears the mark from which helper answered a check, and sets `seen`
    /// to whether a stale one serves the app. A check that did not tell
    /// (`AudioHelperIdentity.notIdentified`) changes neither.
    func update(from identity: AudioHelperIdentity, seen: inout Bool) {
        switch identity {
        case .notIdentified: return
        case .current: clear()
        case .stale: record()
        }
        seen = identity == .stale
    }
}

/// When the Mac last started.
internal enum BootTime {
    /// `kern.boottime` in microseconds since 1970, or nil when it can't be read.
    static func current() -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Int(value.tv_sec) * 1_000_000 + Int(value.tv_usec)
    }
}
