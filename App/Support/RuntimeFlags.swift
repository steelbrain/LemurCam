import Foundation

internal enum RuntimeFlags {
    static let launchedResolution = LemurCamConfig.storedResolution
    static let launchedFrameRate = LemurCamConfig.storedFrameRate

    static var needsRestart: Bool {
        LemurCamConfig.storedResolution != launchedResolution
            || LemurCamConfig.storedFrameRate != launchedFrameRate
    }
}
