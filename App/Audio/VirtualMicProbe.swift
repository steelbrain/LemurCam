import CoreAudio
import Foundation

/// Queries the CoreAudio HAL for the live running state of the LemurCam virtual
/// microphone. Used at launch to recover audio demand the app would otherwise miss:
/// the driver signals new consumers with a fire-and-forget Darwin notification, and
/// one that fired before the app registered its observers is never replayed — so an
/// app launched while the mic is already in use must reconcile against the device's
/// actual state instead of assuming no consumer.
///
/// The CoreAudio calls need a live device and are exercised on-device; the launch
/// wiring that consumes this is unit-tested via an injected probe (see
/// `StreamCoordinator`'s `audioConsumerProbe`).
internal enum VirtualMicProbe {
    /// Whether the virtual microphone device is currently running IO for some consumer.
    /// Returns false if the device can't be found or the query fails.
    static func isVirtualMicRunning() -> Bool {
        guard let deviceID = virtualMicDeviceID() else { return false }
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    /// Translate the virtual mic's stable UID to its current `AudioObjectID`, or nil if
    /// the device isn't present (driver not installed, or not yet registered).
    private static func virtualMicDeviceID() -> AudioObjectID? {
        var cfUID = LEMUR_AUDIO_DEVICE_UID as CFString
        var translated = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &translated) { outPtr in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address,
                    UInt32(MemoryLayout<CFString>.size), uidPtr, &size, outPtr
                )
            }
        }
        guard status == noErr, translated != kAudioObjectUnknown else { return nil }
        return translated
    }
}
