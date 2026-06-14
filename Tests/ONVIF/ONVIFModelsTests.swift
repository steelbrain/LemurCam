@testable import LemurCam
import XCTest

/// Pure model logic: the human-readable `ONVIFProfile.displayName` shown in the
/// profile picker, and the localized `ONVIFError` descriptions surfaced to users.
internal final class ONVIFModelsTests: XCTestCase {

    // MARK: - ONVIFProfile.displayName

    func testDisplayNameWithNameResolutionAndCodec() {
        let profile = ONVIFProfile(token: "t", name: "Main", width: 1920, height: 1080, codec: "H264")
        XCTAssertEqual(profile.displayName, "Main 1920x1080 H264")
    }

    func testDisplayNameNameOnly() {
        let profile = ONVIFProfile(token: "t", name: "Main", width: nil, height: nil, codec: nil)
        XCTAssertEqual(profile.displayName, "Main")
    }

    func testDisplayNameNameAndCodecNoResolution() {
        let profile = ONVIFProfile(token: "t", name: "Sub", width: nil, height: nil, codec: "H265")
        XCTAssertEqual(profile.displayName, "Sub H265")
    }

    func testDisplayNameNameAndResolutionNoCodec() {
        let profile = ONVIFProfile(token: "t", name: "Cam", width: 640, height: 480, codec: nil)
        XCTAssertEqual(profile.displayName, "Cam 640x480")
    }

    /// Resolution requires BOTH width and height; a half-specified resolution is
    /// dropped entirely rather than rendering "1920x" or "x1080".
    func testDisplayNameDropsResolutionWhenHeightMissing() {
        let profile = ONVIFProfile(token: "t", name: "Cam", width: 1920, height: nil, codec: nil)
        XCTAssertEqual(profile.displayName, "Cam")
    }

    func testDisplayNameDropsResolutionWhenWidthMissing() {
        let profile = ONVIFProfile(token: "t", name: "Cam", width: nil, height: 1080, codec: "H264")
        XCTAssertEqual(profile.displayName, "Cam H264")
    }

    // MARK: - ONVIFProfile identity & equality

    func testProfileIDIsToken() {
        let profile = ONVIFProfile(token: "profile_7", name: "x", width: nil, height: nil, codec: nil)
        XCTAssertEqual(profile.id, "profile_7")
    }

    func testProfileEquality() {
        let lhs = ONVIFProfile(token: "t", name: "n", width: 1, height: 2, codec: "c")
        let rhs = ONVIFProfile(token: "t", name: "n", width: 1, height: 2, codec: "c")
        let different = ONVIFProfile(token: "t", name: "n", width: 1, height: 2, codec: "d")
        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, different)
    }

    // MARK: - ONVIFError.errorDescription

    func testErrorDescriptions() {
        XCTAssertEqual(ONVIFError.invalidURL.errorDescription, "Invalid ONVIF device URL")
        XCTAssertEqual(ONVIFError.networkError("boom").errorDescription, "Network error: boom")
        XCTAssertEqual(ONVIFError.soapFault("bad creds").errorDescription, "ONVIF error: bad creds")
        XCTAssertEqual(ONVIFError.parseError.errorDescription, "Failed to parse ONVIF response")
        XCTAssertEqual(ONVIFError.authenticationFailed.errorDescription, "Authentication failed")
    }

    func testErrorDescriptionInterpolatesEmptyMessage() {
        XCTAssertEqual(ONVIFError.networkError("").errorDescription, "Network error: ")
    }
}
