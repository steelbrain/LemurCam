import Foundation

/// The Video Buffer setting: how much of a camera's video the jitter buffer holds
/// before sending it on to the virtual camera. More rides out longer pauses in the
/// camera's delivery; less delays the picture less, which matters when it has to
/// line up with sound from a microphone that isn't the camera's.
internal enum VideoBufferSetting: Int, CaseIterable, Identifiable, Sendable {
    /// No buffer: each frame goes on as soon as it is decoded.
    case off = 0
    case ms100 = 100
    /// The tuned buffer: `Tuning.jitterBufferPrimingThreshold` frames at
    /// `Tuning.jitterBufferDefaultDrainFPS`.
    case ms200 = 200

    static let defaultValue: Self = .ms200

    var id: Int { rawValue }

    var milliseconds: Int { rawValue }

    var label: String {
        self == .off ? "Off" : "\(milliseconds) ms"
    }
}

/// Where the Video Buffer setting is kept: the app's own defaults, like the active
/// camera, since only the app uses it. Injectable for tests.
internal struct VideoBufferStore {
    private static let key = "LemurCam.videoBuffer"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored setting, or the default when none (or an unknown one) is stored.
    var setting: VideoBufferSetting {
        get {
            // Not `integer(forKey:)`: it reads a missing value as 0, which is Off.
            guard let raw = defaults.object(forKey: Self.key) as? Int,
                  let value = VideoBufferSetting(rawValue: raw) else {
                return .defaultValue
            }
            return value
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }

    /// Forget the stored setting (the Reset button), so the default applies, including
    /// a default a later version changes.
    func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
