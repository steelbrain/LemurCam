@testable import LemurCam
import XCTest

/// Pins the Video Buffer setting's choices and how it is stored. Off is stored as 0,
/// which `UserDefaults.integer(forKey:)` also returns for a missing value, so a read
/// through it would turn a fresh install's buffer off.
internal final class VideoBufferSettingTests: XCTestCase {
    func testTheChoicesAndTheirLabels() {
        XCTAssertEqual(VideoBufferSetting.allCases, [.off, .ms100, .ms200])
        XCTAssertEqual(VideoBufferSetting.allCases.map(\.label), ["Off", "100 ms", "200 ms"])
    }

    /// The default is the tuned start-up cushion, so it changes nothing for anyone
    /// who never touches the setting.
    func testTheDefaultIsTheTunedCushion() {
        let tuned = Double(Tuning.jitterBufferPrimingThreshold) / Tuning.jitterBufferDefaultDrainFPS
        XCTAssertEqual(VideoBufferSetting.defaultValue, .ms200)
        XCTAssertEqual(Double(VideoBufferSetting.defaultValue.milliseconds) / 1000, tuned, accuracy: 1e-12)
    }

    func testNothingStoredReadsAsTheDefault() throws {
        XCTAssertEqual(VideoBufferStore(defaults: try freshDefaults("empty")).setting, .defaultValue)
    }

    func testEverySettingIsKept() throws {
        let defaults = try freshDefaults("round-trip")
        for setting in VideoBufferSetting.allCases {
            VideoBufferStore(defaults: defaults).setting = setting
            XCTAssertEqual(VideoBufferStore(defaults: defaults).setting, setting, "\(setting)")
        }
    }

    /// A value this version doesn't offer (from another version, or edited by hand)
    /// reads as the default.
    func testAnUnknownValueReadsAsTheDefault() throws {
        let defaults = try freshDefaults("unknown")
        defaults.set(150, forKey: "LemurCam.videoBuffer")
        XCTAssertEqual(VideoBufferStore(defaults: defaults).setting, .defaultValue)
        defaults.set("off", forKey: "LemurCam.videoBuffer")
        XCTAssertEqual(VideoBufferStore(defaults: defaults).setting, .defaultValue)
    }

    /// An isolated, empty `UserDefaults` suite for a single test.
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "VideoBufferSettingTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}
