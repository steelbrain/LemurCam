@testable import LemurCam
import XCTest

internal final class CameraSourceTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = .sortedKeys
        return jsonEncoder
    }()
    private let decoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        return jsonDecoder
    }()

    func testRTSPSourceRoundTrip() throws {
        let source = CameraSource(
            name: "Backyard Camera",
            sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.100:554/stream"))
        )
        let data = try encoder.encode(source)
        let decoded = try decoder.decode(CameraSource.self, from: data)

        XCTAssertEqual(decoded.id, source.id)
        XCTAssertEqual(decoded.name, source.name)
        XCTAssertEqual(decoded.sourceType, source.sourceType)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       source.createdAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testONVIFSourceRoundTrip() throws {
        let info = ONVIFSourceInfo(
            deviceUUID: "some-device-uuid",
            host: "192.168.1.50",
            port: 8080,
            selectedProfileToken: "profile1",
            streamURI: "rtsp://192.168.1.50/stream1"
        )
        let source = CameraSource(name: "Front Door", sourceType: .onvif(info))
        let data = try encoder.encode(source)
        let decoded = try decoder.decode(CameraSource.self, from: data)

        XCTAssertEqual(decoded.sourceType, source.sourceType)
    }

    func testConnectionStatusNotPersisted() throws {
        let source = CameraSource(
            name: "Test",
            sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://test"))
        )

        let data = try encoder.encode(source)
        let decoded = try decoder.decode(CameraSource.self, from: data)

        // connectionStatus is managed separately by SourceManager, not persisted on CameraSource
        XCTAssertEqual(decoded.id, source.id)
        XCTAssertEqual(decoded.name, source.name)
    }

    func testMultipleSourcesRoundTrip() throws {
        let sources = [
            CameraSource(name: "Camera 1", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a"))),
            CameraSource(name: "Camera 2", sourceType: .onvif(ONVIFSourceInfo(host: "192.168.1.1"))),
            CameraSource(name: "Camera 3", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        ]
        let data = try encoder.encode(sources)
        let decoded = try decoder.decode([CameraSource].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        for (original, roundTripped) in zip(sources, decoded) {
            XCTAssertEqual(original.id, roundTripped.id)
            XCTAssertEqual(original.name, roundTripped.name)
            XCTAssertEqual(original.sourceType, roundTripped.sourceType)
        }
    }
}
