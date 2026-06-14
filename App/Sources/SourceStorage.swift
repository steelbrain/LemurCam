import Foundation
import os

internal final class SourceStorage {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = appSupport
                .appendingPathComponent("LemurCam")
                .appendingPathComponent("sources.json")
        }
    }

    func load() -> [CameraSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([CameraSource].self, from: data)
        } catch {
            Log.app.error("Failed to load sources: \(error)")
            return []
        }
    }

    func save(_ sources: [CameraSource]) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sources)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Failed to save sources: \(error)")
        }
    }
}
