import AppIntents
import AppKit
import Foundation

internal struct CameraEntity: AppEntity {
    static let defaultQuery = CameraEntityQuery()
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"

    var id: UUID
    var name: String
    var sourceTypeName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(sourceTypeName)")
    }
}

internal struct CameraEntityQuery: EntityQuery, EnumerableEntityQuery {
    static var findIntentDescription: IntentDescription? {
        IntentDescription("Find a LemurCam camera source", categoryName: "Camera")
    }

    func entities(for identifiers: [UUID]) async -> [CameraEntity] {
        let all = await allEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func allEntities() async -> [CameraEntity] {
        await MainActor.run {
            guard let delegate = NSApp.delegate as? AppDelegate else { return [] }
            return delegate.sourceManager.sources.map { source in
                CameraEntity(
                    id: source.id,
                    name: source.name,
                    sourceTypeName: source.sourceType.displayName
                )
            }
        }
    }

    func suggestedEntities() async -> [CameraEntity] {
        await allEntities()
    }
}

private extension SourceType {
    var displayName: String {
        switch self {
        case .onvif: return "ONVIF"
        case .rtsp: return "RTSP"
        }
    }
}
