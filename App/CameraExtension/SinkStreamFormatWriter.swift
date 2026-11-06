import CoreMedia
import CoreMediaIO

/// Tells the camera extension the user's Resolution and Frame Rate settings. The
/// extension runs as another user, so the app group can't carry them. Instead the
/// app sets the standard CMIO format and frame-rate properties of the sink stream,
/// which only this app uses: CMIO hands them to the extension as the sink's
/// active format index and frame duration, and the extension makes them the
/// default of the stream other apps capture from (`SourceFormatState`).
internal enum SinkStreamFormatWriter {
    /// Sets `format` on the sink stream `streamID`. Returns whether both the
    /// format and the frame rate were set.
    @discardableResult
    static func write(_ format: StreamFormatSelection, toStream streamID: CMIOStreamID) -> Bool {
        let descriptions = formatDescriptions(of: streamID)
        guard !descriptions.isEmpty else { return false }
        let dimensions = descriptions.map { CMVideoFormatDescriptionGetDimensions($0) }
        guard let index = StreamFormatTable.index(of: format.resolution, among: dimensions) else {
            // An extension older than this app offers fewer formats on its sink.
            Log.ipc.error("The virtual camera has no \(format.resolution.rawValue) format to set")
            return false
        }
        let formatSet = setFormatDescription(descriptions[index], on: streamID)
        let rateSet = setFrameRate(Float64(format.frameRate.rawValue), on: streamID)
        guard formatSet, rateSet else { return false }
        Log.ipc.info("Set the virtual camera's format to \(format.resolution.rawValue) at \(format.frameRate.label)")
        return true
    }

    /// `kCMIOStreamPropertyFormatDescriptions`: the stream's formats, in the
    /// extension's order. Empty when they can't be read.
    private static func formatDescriptions(of streamID: CMIOStreamID) -> [CMFormatDescription] {
        var address = propertyAddress(kCMIOStreamPropertyFormatDescriptions)
        var list: Unmanaged<CFArray>?
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            streamID, &address, 0, nil,
            UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &dataUsed, &list
        )
        // The caller owns the array (CMIOHardwareStream.h).
        let array = list?.takeRetainedValue()
        guard status == noErr, let descriptions = array as? [CMFormatDescription] else {
            Log.ipc.error("Couldn't read the virtual camera's formats: \(status)")
            return []
        }
        return descriptions
    }

    /// `kCMIOStreamPropertyFormatDescription`, set to one of the stream's own
    /// formats, which the header names as a valid value.
    private static func setFormatDescription(_ description: CMFormatDescription, on streamID: CMIOStreamID) -> Bool {
        var address = propertyAddress(kCMIOStreamPropertyFormatDescription)
        var value = description
        let status = CMIOObjectSetPropertyData(
            streamID, &address, 0, nil, UInt32(MemoryLayout<CMFormatDescription>.size), &value
        )
        guard status == noErr else {
            Log.ipc.error("Couldn't set the virtual camera's format: \(status)")
            return false
        }
        return true
    }

    /// `kCMIOStreamPropertyFrameRate`, a Float64 in frames per second.
    private static func setFrameRate(_ rate: Float64, on streamID: CMIOStreamID) -> Bool {
        var address = propertyAddress(kCMIOStreamPropertyFrameRate)
        var value = rate
        let status = CMIOObjectSetPropertyData(
            streamID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value
        )
        guard status == noErr else {
            Log.ipc.error("Couldn't set the virtual camera's frame rate: \(status)")
            return false
        }
        return true
    }

    private static func propertyAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
