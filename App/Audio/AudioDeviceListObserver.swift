import CoreAudio
import Foundation

/// Watches the CoreAudio HAL device list and calls `handler` on `queue` after each
/// change, such as the virtual microphone appearing or disappearing when the helper
/// installs or removes its driver and restarts coreaudiod, and after each coreaudiod
/// restart. Mirrors `CMIODeviceListObserver`.
///
/// Create it on `queue`, not the main thread: adding the listener can be the
/// process's first CoreAudio call, which waits for the HAL to initialize. The HAL
/// documents that a restarted coreaudiod has dropped the listeners a client added
/// (`kAudioHardwarePropertyServiceRestarted`), so the device-list listener is
/// added again on every restart.
///
/// Retain the instance for as long as notifications are wanted; `deinit` removes
/// the listeners. Failable: returns nil if the listener can't be installed.
internal final class AudioDeviceListObserver {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var devicesAddress = AudioDeviceListObserver.address(kAudioHardwarePropertyDevices)
    private var restartAddress = AudioDeviceListObserver.address(kAudioHardwarePropertyServiceRestarted)
    private let queue: DispatchQueue
    private let devicesListener: AudioObjectPropertyListenerBlock
    private var restartListener: AudioObjectPropertyListenerBlock?

    init?(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.devicesListener = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddress, queue, devicesListener)
        guard status == noErr else {
            Log.app.error("Failed to add the audio device-list listener: \(status)")
            return nil
        }
        // Runs on `queue`, like the device-list listener it adds again.
        let onRestart: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.addDevicesListenerAgain()
            handler()
        }
        restartListener = onRestart
        let restartStatus = AudioObjectAddPropertyListenerBlock(systemObject, &restartAddress, queue, onRestart)
        if restartStatus != noErr {
            Log.app.error("Failed to add the coreaudiod restart listener: \(restartStatus)")
        }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(systemObject, &devicesAddress, queue, devicesListener)
        if let restartListener {
            AudioObjectRemovePropertyListenerBlock(systemObject, &restartAddress, queue, restartListener)
        }
    }

    /// Remove first, so a listener that did survive the restart isn't added twice.
    private func addDevicesListenerAgain() {
        AudioObjectRemovePropertyListenerBlock(systemObject, &devicesAddress, queue, devicesListener)
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &devicesAddress, queue, devicesListener)
        if status != noErr {
            Log.app.error("Failed to add the audio device-list listener after a coreaudiod restart: \(status)")
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
