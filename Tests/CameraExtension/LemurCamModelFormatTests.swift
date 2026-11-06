import CoreMediaIO
@testable import LemurCam
import os
import XCTest

/// Locks when the app hands the camera extension the user's Resolution and Frame
/// Rate settings, through the sink stream's format properties. The extension
/// can't read the app's settings, and loses what it was told when it restarts,
/// so the app sets them on every newly found device and after every change. It
/// used to read them only at launch, and only in the app, so the camera other
/// apps saw never changed.
@MainActor
internal final class LemurCamModelFormatTests: XCTestCase {
    private struct Write: Equatable {
        let format: StreamFormatSelection
        let streamID: CMIOStreamID
    }

    private let device: (deviceID: CMIODeviceID, streamID: CMIOStreamID) = (deviceID: 10, streamID: 11)
    private let replacement: (deviceID: CMIODeviceID, streamID: CMIOStreamID) = (deviceID: 20, streamID: 21)
    private let hd720 = StreamFormatSelection(resolution: .hd720, frameRate: .fps30)
    private let uhd4k = StreamFormatSelection(resolution: .uhd4k, frameRate: .fps60)

    private let writes = OSAllocatedUnfairLock<[Write]>(initialState: [])
    private let setting = OSAllocatedUnfairLock<StreamFormatSelection>(
        initialState: StreamFormatSelection(resolution: .hd720, frameRate: .fps30)
    )

    /// A model that records each format write instead of making CMIO calls, and
    /// fulfills `written` for each. Writes run on the model's discovery queue, in
    /// order, so waiting for the last expected one shows every earlier one too.
    private func makeModel(written: XCTestExpectation) -> LemurCamModel {
        LemurCamModel(
            consumerProbe: { _ in false },
            deviceListReader: { .empty },
            consumerObserver: { _ in nil },
            formatWriter: { [writes] format, streamID in
                writes.withLock { $0.append(Write(format: format, streamID: streamID)) }
                written.fulfill()
            },
            preferredFormat: { [setting] in setting.withLock { $0 } }
        )
    }

    private func expectWrites(_ count: Int) -> XCTestExpectation {
        let written = expectation(description: "format writes")
        written.expectedFulfillmentCount = count
        written.assertForOverFulfill = true
        return written
    }

    private var recorded: [Write] { writes.withLock { $0 } }

    func testDiscoveringTheDeviceSetsTheSettingOnItsSinkStream() async {
        let written = expectWrites(1)
        let model = makeModel(written: written)

        model.applyDiscoveryResult(device)

        await fulfillment(of: [written], timeout: 5)
        XCTAssertEqual(recorded, [Write(format: hd720, streamID: device.streamID)])
    }

    func testChangingTheSettingSetsItOnTheCachedSinkStream() async {
        let written = expectWrites(2)
        let model = makeModel(written: written)
        model.applyDiscoveryResult(device)

        setting.withLock { [uhd4k] in $0 = uhd4k }
        model.applyPreferredFormat()

        await fulfillment(of: [written], timeout: 5)
        XCTAssertEqual(recorded, [
            Write(format: hd720, streamID: device.streamID),
            Write(format: uhd4k, streamID: device.streamID)
        ])
    }

    /// Finding the cached device again means the same extension, which still has
    /// the setting; an app may have chosen another format since.
    func testRediscoveringTheCachedDeviceDoesNotSetItAgain() async {
        let written = expectWrites(2)
        let model = makeModel(written: written)
        model.applyDiscoveryResult(device)

        model.applyDiscoveryResult(device)
        model.applyDiscoveryResult(nil)
        setting.withLock { [uhd4k] in $0 = uhd4k }
        model.applyPreferredFormat()

        await fulfillment(of: [written], timeout: 5)
        XCTAssertEqual(recorded.map(\.format), [hd720, uhd4k], "only discovery and the change set it")
    }

    func testAChangeBeforeDiscoverySetsNothingUntilTheDeviceIsFound() async {
        let written = expectWrites(1)
        let model = makeModel(written: written)

        model.applyPreferredFormat()
        setting.withLock { [uhd4k] in $0 = uhd4k }
        model.applyDiscoveryResult(device)

        await fulfillment(of: [written], timeout: 5)
        XCTAssertEqual(recorded, [Write(format: uhd4k, streamID: device.streamID)])
    }

    /// A restarted, re-enabled or repaired extension comes back as a new device,
    /// in its default format.
    func testANewDeviceAfterTheOldOneWentAwayGetsTheSetting() async {
        let written = expectWrites(2)
        let model = makeModel(written: written)
        model.applyDiscoveryResult(device)

        model.applyDeviceListChange(.empty)
        model.applyPreferredFormat()
        model.applyDiscoveryResult(replacement)

        await fulfillment(of: [written], timeout: 5)
        XCTAssertEqual(recorded, [
            Write(format: hd720, streamID: device.streamID),
            Write(format: hd720, streamID: replacement.streamID)
        ], "nothing goes to the lost device's stream")
    }

    func testAReplacedDeviceGetsTheSettingOnItsOwnSinkStream() async {
        let written = expectWrites(3)
        let model = makeModel(written: written)
        model.applyDiscoveryResult(device)

        model.applyDeviceListChange(.lemur(replacement.deviceID))
        model.applyDiscoveryResult(replacement)
        model.applyPreferredFormat()

        await fulfillment(of: [written], timeout: 5)
        XCTAssertEqual(recorded.map(\.streamID), [device.streamID, replacement.streamID, replacement.streamID])
    }
}
