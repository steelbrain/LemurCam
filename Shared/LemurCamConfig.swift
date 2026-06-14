import Foundation

internal enum LemurCamConfig {
    static let cameraExtensionID = "cam.lemur.app.extension"
    static let virtualCameraName = "LemurCam"
    static let deviceID = "E4695A2A-64BB-4A36-A538-EFE4279631ED"
    static let videoID = "085D71B8-586D-4229-9BAE-D9FDA1618504"
    static let sinkStreamID = "905571D5-0D01-428A-B6C7-E3E4D0AEDA64"

    static let appGroupID = "2KG9772KH6.cam.lemur.app"

    // MARK: - Resolution

    enum Resolution: String, CaseIterable, Identifiable {
        case hd720 = "720p"
        case hd1080 = "1080p"
        case qhd1440 = "1440p"
        case uhd4k = "4K"

        var id: String { rawValue }

        var width: Int32 {
            switch self {
            case .hd720: return 1280
            case .hd1080: return 1920
            case .qhd1440: return 2560
            case .uhd4k: return 3840
            }
        }

        var height: Int32 {
            switch self {
            case .hd720: return 720
            case .hd1080: return 1080
            case .qhd1440: return 1440
            case .uhd4k: return 2160
            }
        }
    }

    // MARK: - Frame Rate

    enum FrameRate: Int, CaseIterable, Identifiable {
        case fps30 = 30
        case fps60 = 60

        var id: Int { rawValue }

        var label: String {
            "\(rawValue) fps"
        }
    }

    // MARK: - Shared Defaults

    static let activeSourceKey = "LemurCam.activeSourceID"
    static let hasExternalConsumersKey = "LemurCam.hasExternalConsumers"
    static var consumerStartedNotification: CFString {
        "cam.lemur.consumerStarted" as CFString
    }
    static var consumerStoppedNotification: CFString {
        "cam.lemur.consumerStopped" as CFString
    }

    /// The `CFBundleVersion` the *running* camera extension last published. The
    /// extension stamps it at startup; the app reads it to detect a stale
    /// post-upgrade extension (macOS can keep an old version resident after an
    /// in-place update). See `ExtensionUpgradeDecision`.
    static let runningExtensionVersionKey = "LemurCam.runningExtensionVersion"

    private static let resolutionKey = "LemurCam.resolution"
    private static let frameRateKey = "LemurCam.frameRate"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Called by the camera extension at startup to publish the version of the
    /// code that is actually executing. In the extension process `Bundle.main` is
    /// the extension bundle, so this records the live extension's `CFBundleVersion`
    /// (= `CURRENT_PROJECT_VERSION`).
    static func recordRunningExtensionVersion() {
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        sharedDefaults?.set(version, forKey: runningExtensionVersionKey)
    }

    /// The version the live extension last published via `recordRunningExtensionVersion`,
    /// or nil if none has (e.g. a pre-handshake build, or the extension isn't running).
    static var runningExtensionVersion: String? {
        sharedDefaults?.string(forKey: runningExtensionVersionKey)
    }

    static var storedResolution: Resolution {
        get {
            guard let raw = sharedDefaults?.string(forKey: resolutionKey),
                  let value = Resolution(rawValue: raw) else {
                return .hd1080
            }
            return value
        }
        set {
            sharedDefaults?.set(newValue.rawValue, forKey: resolutionKey)
        }
    }

    static var storedFrameRate: FrameRate {
        get {
            guard let raw = sharedDefaults?.integer(forKey: frameRateKey),
                  raw != 0,
                  let value = FrameRate(rawValue: raw) else {
                return .fps60
            }
            return value
        }
        set {
            sharedDefaults?.set(newValue.rawValue, forKey: frameRateKey)
        }
    }

    // Backward-compatible computed property
    static var frameRate: Int {
        storedFrameRate.rawValue
    }
}
