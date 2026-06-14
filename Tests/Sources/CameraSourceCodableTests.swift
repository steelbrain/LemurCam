@testable import LemurCam
import XCTest

/// Pins the on-disk JSON schema for persisted sources. Decoding fixed literals is
/// the load path that reads *existing users'* files, so a change to `CodingKeys`
/// or the `SourceType` enum layout (`{"rtsp":{"_0":{…}}}`) that silently broke
/// reads would fail here instead of wiping someone's saved cameras on upgrade.
internal final class CameraSourceCodableTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        return jsonDecoder
    }()
    private let encoder: JSONEncoder = {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.sortedKeys]
        return jsonEncoder
    }()

    private func iso(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: string))
    }

    // MARK: - decode from fixed schema

    func testDecodeRTSPFromFixedSchema() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Backyard",
          "createdAt": "2026-01-02T03:04:05Z",
          "updatedAt": "2026-01-02T03:04:06Z",
          "sourceType": { "rtsp": { "_0": { "url": "rtsp://cam/stream" } } }
        }
        """
        let source = try decoder.decode(CameraSource.self, from: Data(json.utf8))

        XCTAssertEqual(source.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(source.name, "Backyard")
        XCTAssertEqual(source.createdAt, try iso("2026-01-02T03:04:05Z"))
        XCTAssertEqual(source.updatedAt, try iso("2026-01-02T03:04:06Z"))
        XCTAssertEqual(source.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://cam/stream")))
    }

    func testDecodeONVIFFromFixedSchema() throws {
        let json = """
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "name": "Front Door",
          "createdAt": "2026-01-02T03:04:05Z",
          "updatedAt": "2026-01-02T03:04:05Z",
          "sourceType": { "onvif": { "_0": {
            "deviceUUID": "dev-1", "host": "10.0.0.5", "port": 8080,
            "selectedProfileToken": "tok-1", "streamURI": "rtsp://10.0.0.5/s"
          } } }
        }
        """
        let source = try decoder.decode(CameraSource.self, from: Data(json.utf8))

        let expected = ONVIFSourceInfo(
            deviceUUID: "dev-1", host: "10.0.0.5", port: 8080,
            selectedProfileToken: "tok-1", streamURI: "rtsp://10.0.0.5/s"
        )
        XCTAssertEqual(source.sourceType, .onvif(expected))
    }

    /// ONVIF optionals are genuinely optional: absent keys decode to nil while the
    /// required host/port still parse.
    func testDecodeONVIFWithOnlyRequiredFields() throws {
        let json = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "name": "Minimal",
          "createdAt": "2026-01-02T03:04:05Z",
          "updatedAt": "2026-01-02T03:04:05Z",
          "sourceType": { "onvif": { "_0": { "host": "192.168.0.9", "port": 80 } } }
        }
        """
        let source = try decoder.decode(CameraSource.self, from: Data(json.utf8))

        guard case .onvif(let info) = source.sourceType else { XCTFail("expected onvif"); return }
        XCTAssertEqual(info.host, "192.168.0.9")
        XCTAssertEqual(info.port, 80)
        XCTAssertNil(info.deviceUUID)
        XCTAssertNil(info.selectedProfileToken)
        XCTAssertNil(info.streamURI)
    }

    /// `ONVIFSourceInfo.port` carries a `= 80` default in its declaration, but Swift's
    /// synthesized `Codable` does NOT apply property defaults — a missing `port` key
    /// throws `keyNotFound`. Persisted ONVIF sources therefore always carry `port` on
    /// disk. Pin that so a future custom decoder (or a "make port optional" change)
    /// that silently alters the on-disk contract is a deliberate, visible decision.
    func testDecodeONVIFThrowsWhenPortKeyMissing() {
        let json = """
        {
          "id": "44444444-4444-4444-4444-444444444444",
          "name": "No Port",
          "createdAt": "2026-01-02T03:04:05Z",
          "updatedAt": "2026-01-02T03:04:05Z",
          "sourceType": { "onvif": { "_0": { "host": "192.168.0.9" } } }
        }
        """
        XCTAssertThrowsError(try decoder.decode(CameraSource.self, from: Data(json.utf8)))
    }

    // MARK: - round trip preserves all fields

    func testRoundTripPreservesUpdatedAt() throws {
        let created = try iso("2026-03-04T05:06:07Z")
        let updated = try iso("2026-03-04T08:09:10Z")
        let source = CameraSource(
            name: "Cam", sourceType: .onvif(ONVIFSourceInfo(host: "h")),
            createdAt: created, updatedAt: updated
        )

        let decoded = try decoder.decode(CameraSource.self, from: try encoder.encode(source))

        XCTAssertEqual(decoded.createdAt, created)
        XCTAssertEqual(decoded.updatedAt, updated)
    }

    // MARK: - SourceStorage robustness

    func testStorageReturnsEmptyForCorruptJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{ this is not valid json".utf8).write(to: url)

        // Corruption degrades to "no sources", never a crash or a throw.
        XCTAssertTrue(SourceStorage(fileURL: url).load().isEmpty)
    }
}
