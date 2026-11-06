import CoreMediaIO
import Foundation
import os

internal enum CoreMediaIOUtil {

    static func getDeviceIDs() -> [CMIODeviceID] {
        var res: OSStatus
        var opa = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        res = CMIOObjectGetPropertyDataSize(CMIODeviceID(kCMIOObjectSystemObject),
                                            &opa, 0, nil, &dataSize)
        if res != noErr {
            Log.ipc.error("failed CMIOObjectGetPropertyDataSize")
            return []
        }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var dataUsed: UInt32 = 0
        var devices = [CMIODeviceID](repeating: 0, count: count)
        res = CMIOObjectGetPropertyData(CMIODeviceID(kCMIOObjectSystemObject),
                                        &opa, 0, nil, dataSize, &dataUsed, &devices)
        if res != noErr {
            Log.ipc.error("failed CMIOObjectGetPropertyData")
            return []
        }
        return devices
    }

    static func getDeviceUID(deviceID: CMIODeviceID) -> String? {
        var res: OSStatus
        var opa = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        res = CMIOObjectGetPropertyDataSize(deviceID, &opa, 0, nil, &dataSize)
        if res != noErr {
            Log.ipc.error("failed CMIOObjectGetPropertyDataSize")
            return nil
        }
        var dataUsed: UInt32 = 0
        let alignment = MemoryLayout<Unmanaged<CFString>>.alignment
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: alignment)
        defer { ptr.deallocate() }
        res = CMIOObjectGetPropertyData(deviceID, &opa, 0, nil, dataSize, &dataUsed, ptr)
        if res != noErr {
            Log.ipc.error("failed CMIOObjectGetPropertyData")
            return nil
        }
        let unmanaged = ptr.load(as: Unmanaged<CFString>.self)
        let cfString = unmanaged.takeRetainedValue()
        return cfString as String
    }

    static func getStreams(deviceID: CMIODeviceID) -> [CMIOStreamID] {
        var res: OSStatus
        var opa = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        res = CMIOObjectGetPropertyDataSize(deviceID, &opa, 0, nil, &dataSize)
        if res != noErr {
            Log.ipc.error("failed CMIOObjectGetPropertyDataSize")
            return []
        }
        var dataUsed: UInt32 = 0
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        res = CMIOObjectGetPropertyData(deviceID, &opa, 0, nil, dataSize, &dataUsed, &streams)
        if res != noErr {
            Log.ipc.error("failed CMIOObjectGetPropertyData")
            return []
        }
        return streams
    }

    /// The CMIO device ID for the LemurCam virtual camera, matched by the fixed
    /// device UID the extension advertises (`LemurCamConfig.deviceID`). Returns nil
    /// when the extension is not installed/loaded, so this doubles as a presence
    /// check that needs neither AVFoundation nor camera permission.
    static func lemurDeviceID() -> CMIODeviceID? {
        getDeviceIDs().first {
            getDeviceUID(deviceID: $0)?.caseInsensitiveCompare(LemurCamConfig.deviceID) == .orderedSame
        }
    }

    /// Whether the given device reports `kCMIODevicePropertyDeviceIsAlive` — i.e.
    /// it is ready and selectable by other apps. The most direct liveness signal,
    /// independent of AVFoundation discovery and camera authorization.
    static func isAlive(deviceID: CMIODeviceID) -> Bool {
        let value = readUInt32Property(
            deviceID: deviceID,
            selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsAlive),
            name: "kCMIODevicePropertyDeviceIsAlive"
        )
        return (value ?? 0) != 0
    }

    /// The raw `kCMIODevicePropertyDeviceIsRunningSomewhere` value (1 when any
    /// process on the system is doing IO on the device), or nil if unreadable.
    static func runningSomewhereValue(deviceID: CMIODeviceID) -> UInt32? {
        readUInt32Property(
            deviceID: deviceID,
            selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            name: "kCMIODevicePropertyDeviceIsRunningSomewhere"
        )
    }

    /// Whether an external app is using the given (already discovered) LemurCam
    /// device. Only meaningful before this app starts its own sink stream on it;
    /// see `CameraConsumerProbe`.
    static func hasExternalConsumer(deviceID: CMIODeviceID) -> Bool {
        CameraConsumerProbe.hasExternalConsumer(deviceID: deviceID, readRunningSomewhere: runningSomewhereValue)
    }

    /// Whether an external app is using the LemurCam virtual camera, looked up by
    /// its fixed device UID. False when the device isn't present or can't be read.
    /// Only meaningful before this app starts its own sink stream (e.g. at launch).
    static func lemurCameraHasExternalConsumer() -> Bool {
        CameraConsumerProbe.hasExternalConsumer(deviceID: lemurDeviceID(), readRunningSomewhere: runningSomewhereValue)
    }

    /// Reads a UInt32 device property. Returns nil without logging when the device
    /// doesn't expose the property (a device still registering may not yet), and
    /// nil with an error log when the read itself fails.
    private static func readUInt32Property(
        deviceID: CMIODeviceID,
        selector: CMIOObjectPropertySelector,
        name: String
    ) -> UInt32? {
        var opa = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(deviceID, &opa) else { return nil }
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let res = CMIOObjectGetPropertyData(
            deviceID, &opa, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value
        )
        if res != noErr {
            Log.ipc.error("failed to read \(name): \(res)")
            return nil
        }
        return value
    }

    /// Convenience: the LemurCam virtual camera exists and is live/selectable.
    static func isLemurCameraLive() -> Bool {
        guard let deviceID = lemurDeviceID() else { return false }
        return isAlive(deviceID: deviceID)
    }

    static func startStream(
        deviceID: CMIODeviceID,
        streamID: CMIOStreamID,
        queueAlteredProc: CMIODeviceStreamQueueAlteredProc,
        queueAlteredRefCon: UnsafeMutableRawPointer
    ) -> CMSimpleQueue? {
        var res: OSStatus
        var queuePtr: Unmanaged<CMSimpleQueue>?
        res = CMIOStreamCopyBufferQueue(streamID, queueAlteredProc, queueAlteredRefCon, &queuePtr)
        if res != noErr {
            Log.ipc.error("failed CMIOStreamCopyBufferQueue: \(res)")
            return nil
        }

        guard let queue = queuePtr?.takeRetainedValue() else {
            Log.ipc.error("CMIOStreamCopyBufferQueue returned nil queue")
            return nil
        }

        res = CMIODeviceStartStream(deviceID, streamID)
        if res != noErr {
            Log.ipc.error("failed CMIODeviceStartStream: \(res)")
            return nil
        }
        return queue
    }

}

/// Observes CMIO device-list changes (devices appearing/disappearing) and invokes
/// `handler` on `queue` whenever the set changes. The app uses this to pick up the
/// LemurCam virtual camera the moment the extension registers it — converging to
/// `ready` without waiting out the liveness poll or asking the user to relaunch.
///
/// Retain the instance for as long as notifications are wanted; `deinit` removes
/// the listener. Failable: returns nil if the listener can't be installed.
internal final class CMIODeviceListObserver {
    private let objectID = CMIOObjectID(kCMIOObjectSystemObject)
    private var address = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    private let queue: DispatchQueue
    private let block: CMIOObjectPropertyListenerBlock

    init?(queue: DispatchQueue, handler: @escaping () -> Void) {
        self.queue = queue
        self.block = { _, _ in handler() }
        let status = CMIOObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == noErr else {
            Log.ipc.error("failed to add CMIO device-list listener: \(status)")
            return nil
        }
    }

    deinit {
        CMIOObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}
