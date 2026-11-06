import CoreMediaIO
import Foundation

/// Decides whether an external app is already using the LemurCam virtual camera,
/// from the standard CMIO property `kCMIODevicePropertyDeviceIsRunningSomewhere`
/// on the LemurCam device. This replaces the old app-group `hasExternalConsumers`
/// flag: the camera extension runs as `_cmiodalassistants`, so its app-group
/// `UserDefaults` are a different domain from the app's and the flag never reached
/// the app.
///
/// "Running somewhere" counts every process doing IO on the device, including
/// this app once it starts its sink stream. So it means "an external consumer"
/// only at the moments the app reads it: at launch and right after CMIO discovery,
/// both before the app has started its own sink stream on that device.
internal enum CameraConsumerProbe {
    /// False when there is no device, when the property can't be read (today's
    /// behavior without the flag), or when it reads 0.
    static func hasExternalConsumer(
        deviceID: CMIODeviceID?,
        readRunningSomewhere: (CMIODeviceID) -> UInt32?
    ) -> Bool {
        guard let deviceID, let value = readRunningSomewhere(deviceID) else { return false }
        return value != 0
    }
}
