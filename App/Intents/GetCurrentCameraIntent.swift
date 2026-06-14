import AppIntents
import AppKit
import Foundation

internal struct GetCurrentCameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Camera"
    static let description: IntentDescription = "Get the name of the active LemurCam camera source"
    static let openAppWhenRun = false

    func perform() async -> some IntentResult & ReturnsValue<String> {
        let name = await MainActor.run {
            guard let delegate = NSApp.delegate as? AppDelegate,
                  let activeID = delegate.sourceManager.activeSourceID,
                  let source = delegate.sourceManager.sources.first(where: { $0.id == activeID })
            else { return "None" }
            return source.name
        }
        return .result(value: name)
    }
}
