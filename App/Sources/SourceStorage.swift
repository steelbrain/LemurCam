import Foundation

internal final class SourceStorage {
    /// Why saving is refused for the rest of the session.
    enum SaveRefusal: Equatable {
        /// The file could not be read (no permission, an I/O error). It may well be
        /// intact, and the session started without the cameras in it.
        case unreadable
        /// The file is damaged and no copy of it could be kept.
        case damagedAndNotCopied

        /// Shown where the user manages cameras for as long as saving is refused, and
        /// when adding, editing or removing a camera is refused meanwhile.
        var message: String {
            let consequence = "so you can’t add, edit or remove cameras until it restarts."
            switch self {
            case .unreadable:
                return "LemurCam couldn’t read your saved cameras, " + consequence
            case .damagedAndNotCopied:
                return "Your saved cameras file is damaged and LemurCam couldn’t keep a copy of it, " + consequence
            }
        }
    }

    /// Shown where the user manages cameras while `lastSaveFailed` is set.
    static let saveFailureMessage = "LemurCam couldn’t save your cameras, so your latest changes will be "
        + "lost when you quit. It tries again the next time you change a camera."

    private let fileURL: URL
    /// Writes the encoded cameras to the file. Tests pass one that fails.
    private let writeFile: (Data, URL) throws -> Void

    /// Set when the sources file could not be read, or was damaged and could not be
    /// moved or copied aside. Saving is refused for the rest of the session so the
    /// only copy of the user's cameras is kept. It is never lifted early, not even if
    /// the file becomes readable: after a failed read the session holds none of the
    /// file's cameras, and after a failed copy the damaged entries exist nowhere else,
    /// so any save would lose cameras.
    private(set) var saveRefusal: SaveRefusal?

    /// Whether the last save could not write the file (the disk is full, the folder
    /// can't be written to). Unlike `saveRefusal` it refuses nothing: the file still
    /// holds what was saved before, every save tries again, and one that works clears it.
    private(set) var lastSaveFailed = false

    init(
        fileURL: URL? = nil,
        writeFile: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }
    ) {
        self.writeFile = writeFile
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

    /// Loads the saved cameras. Each camera is decoded on its own, so one damaged
    /// entry costs only that entry, and a copy of the file is kept next to it before
    /// the next save drops the entry. A file that can't be decoded as a list at all is
    /// moved aside instead of being overwritten by the next save. Only a file that isn't
    /// there counts as no cameras. One that can't be read (no permission on it or on a
    /// folder above it, an I/O error) may well be intact, so it stays where it is and
    /// nothing is saved over it this session. Logs name the failing field, never its
    /// value, since entries hold URLs and hosts.
    func load() -> [CameraSource] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch where Self.isNoSuchFile(error) {
            return []
        } catch {
            Log.app.error("Saved cameras could not be read (\(Self.describe(error))); leaving the file as it is")
            saveRefusal = .unreadable
            return []
        }
        let entries: [LossyEntry]
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([LossyEntry].self, from: data)
        } catch {
            Log.app.error("Saved cameras could not be decoded (\(Self.describe(error)))")
            preserveDamagedFile(move: true)
            return []
        }

        var sources: [CameraSource] = []
        for (index, entry) in entries.enumerated() {
            switch entry.result {
            case .success(let source):
                sources.append(source)
            case .failure(let error):
                Log.app.error("Skipped saved camera #\(index + 1) (\(Self.describe(error)))")
            }
        }
        if sources.count < entries.count {
            preserveDamagedFile(move: false)
        }
        return sources
    }

    /// Writes `sources` to the file, and returns whether the file now holds them. Not
    /// while saving is refused. When the file can't be written it keeps what it held,
    /// since the write is atomic, and `lastSaveFailed` is set.
    @discardableResult
    func save(_ sources: [CameraSource]) -> Bool {
        guard saveRefusal == nil else {
            Log.app.error("Not saving cameras: the sources file could not be read or moved aside")
            return false
        }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sources)
            try writeFile(data, fileURL)
            lastSaveFailed = false
            return true
        } catch {
            Log.app.error("Failed to save sources (\(Self.describe(error)))")
            lastSaveFailed = true
            return false
        }
    }

    /// Whether reading failed because there is no file (or no folder) at the path. A
    /// folder that can't be searched hides the file instead, and reads as no permission.
    private static func isNoSuchFile(_ error: any Error) -> Bool {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain: return nsError.code == NSFileReadNoSuchFileError
        case NSPOSIXErrorDomain: return nsError.code == Int(ENOENT)
        default: return false
        }
    }

    // MARK: - Damaged files

    /// Keeps the damaged file as `sources.json.corrupt-<UTC timestamp>`: moved when
    /// nothing could be loaded from it, copied when only some entries were skipped.
    private func preserveDamagedFile(move: Bool) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: Date())
        let name = fileURL.lastPathComponent
        let candidates = [
            "\(name).corrupt-\(stamp)",
            "\(name).corrupt-\(stamp)-\(UUID().uuidString.prefix(8))"
        ]
        for candidate in candidates {
            let destination = fileURL.deletingLastPathComponent().appendingPathComponent(candidate)
            do {
                if move {
                    try FileManager.default.moveItem(at: fileURL, to: destination)
                } else {
                    try FileManager.default.copyItem(at: fileURL, to: destination)
                }
                Log.app.error("Kept the damaged sources file as \(candidate)")
                return
            } catch {
                continue
            }
        }
        Log.app.error("Could not keep a copy of the damaged sources file")
        saveRefusal = .damagedAndNotCopied
    }

    /// One array element, decoded without failing the whole array.
    private struct LossyEntry: Decodable {
        let result: Result<CameraSource, any Error>

        init(from decoder: any Decoder) {
            result = Result { try CameraSource(from: decoder) }
        }
    }

    /// The kind of decoding failure and where it happened, by key name only. Values
    /// (URLs, hosts) never appear, since they can carry credentials.
    static func describe(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            // Domain and code only: an NSError's description includes the file path.
            let nsError = error as NSError
            return "\(nsError.domain) \(nsError.code)"
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing \(key.stringValue) at \(path(of: context))"
        case .typeMismatch(_, let context):
            return "wrong type at \(path(of: context))"
        case .valueNotFound(_, let context):
            return "missing value at \(path(of: context))"
        case .dataCorrupted(let context):
            return "invalid data at \(path(of: context))"
        @unknown default:
            return "decoding error"
        }
    }

    private static func path(of context: DecodingError.Context) -> String {
        let keys = context.codingPath.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }
        return keys.isEmpty ? "top level" : keys.joined(separator: ".")
    }
}
