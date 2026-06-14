import AppIntents
import AppKit
import Foundation

internal struct SwitchCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Camera"
    static let description: IntentDescription = "Switch LemurCam to a different camera source"
    static let openAppWhenRun = false

    @Parameter(title: "Camera")
    var camera: CameraEntity

    func perform() async -> some IntentResult {
        await MainActor.run {
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            delegate.sourceManager.setActiveSource(id: camera.id)
        }
        return .result()
    }
}
