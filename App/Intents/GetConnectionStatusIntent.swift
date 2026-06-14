import AppIntents
import AppKit
import Foundation

internal struct GetConnectionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Connection Status"
    static let description: IntentDescription = "Get the connection status of a LemurCam camera source"
    static let openAppWhenRun = false

    @Parameter(title: "Camera")
    var camera: CameraEntity

    func perform() async -> some IntentResult & ReturnsValue<String> {
        let status = await MainActor.run {
            guard let delegate = NSApp.delegate as? AppDelegate else {
                return "Unknown"
            }
            let sm = delegate.sourceManager
            let label = sm.connectionStatuses[camera.id]?.rawValue ?? "Unknown"
            if let error = sm.errorMessages[camera.id] {
                return "\(label): \(error)"
            }
            return label
        }
        return .result(value: status)
    }
}
