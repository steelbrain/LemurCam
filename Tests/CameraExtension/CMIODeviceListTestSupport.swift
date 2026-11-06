import CoreMediaIO
@testable import LemurCam

extension CMIODeviceList {
    /// A device list with no device in it.
    static let empty = Self.read(deviceIDs: [], lemurDeviceID: nil)

    /// A device list holding only the LemurCam device `deviceID`.
    static func lemur(_ deviceID: CMIODeviceID) -> Self {
        .read(deviceIDs: [deviceID], lemurDeviceID: deviceID)
    }
}
