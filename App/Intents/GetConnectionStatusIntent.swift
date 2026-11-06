import AppIntents
import Foundation

internal struct GetConnectionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Connection Status"
    static let description: IntentDescription = "Get the connection status of a LemurCam camera source"
    static let openAppWhenRun = false

    @Parameter(title: "Camera")
    var camera: CameraEntity

    func perform() async -> some IntentResult & ReturnsValue<String> {
        let cameraID = camera.id
        let status = await MainActor.run {
            guard let sourceManager = IntentContext.sourceManager else { return "Unknown" }
            return Self.statusText(for: cameraID, in: sourceManager)
        }
        return .result(value: status)
    }

    @MainActor
    static func statusText(for cameraID: UUID, in sourceManager: SourceManager) -> String {
        let label = sourceManager.connectionStatuses[cameraID]?.rawValue ?? "Unknown"
        if let error = sourceManager.errorMessages[cameraID] {
            return "\(label): \(error)"
        }
        return label
    }
}
