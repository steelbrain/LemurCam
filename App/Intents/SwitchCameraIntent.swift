import AppIntents
import Foundation

internal struct SwitchCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Camera"
    static let description: IntentDescription = "Switch LemurCam to a different camera source"
    static let openAppWhenRun = false

    @Parameter(title: "Camera")
    var camera: CameraEntity

    func perform() async -> some IntentResult {
        let cameraID = camera.id
        await MainActor.run {
            IntentContext.sourceManager?.setActiveSource(id: cameraID)
        }
        return .result()
    }
}
