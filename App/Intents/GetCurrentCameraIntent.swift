import AppIntents
import Foundation

internal struct GetCurrentCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Camera"
    static let description: IntentDescription = "Get the name of the active LemurCam camera source"
    static let openAppWhenRun = false

    func perform() async -> some IntentResult & ReturnsValue<String> {
        let name = await MainActor.run {
            guard let sourceManager = IntentContext.sourceManager else { return "None" }
            return Self.currentCameraName(in: sourceManager)
        }
        return .result(value: name)
    }

    @MainActor
    static func currentCameraName(in sourceManager: SourceManager) -> String {
        guard let activeID = sourceManager.activeSourceID,
              let source = sourceManager.sources.first(where: { $0.id == activeID })
        else { return "None" }
        return source.name
    }
}
