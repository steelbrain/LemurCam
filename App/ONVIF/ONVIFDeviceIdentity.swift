import Foundation

/// Whether the device that answers at a camera's address is the camera saved there.
///
/// A camera is saved with `ONVIFSourceInfo.deviceUUID`: the endpoint UUID from its
/// WS-Discovery replies (the Discover sheet), or the GUID GetEndpointReference reports,
/// which is the same endpoint address (the add/edit form, see
/// `ONVIFSourceInfo.resolvedDeviceUUID`). Before 1.6 the form stored the serial number
/// there instead, with no field of its own, so in a camera saved then nothing tells a
/// serial number from an endpoint UUID, except that endpoint addresses are UUIDs
/// (WS-Discovery's `urn:uuid:` form) and serial numbers aren't.
///
/// So only like is compared with like, ignoring case and a `urn:uuid:` or `uuid:`
/// prefix: a saved UUID with a reported UUID, by value, and a saved identity that is
/// no UUID with a reported one that is none either, but only when the camera was
/// saved with its serial number apart (so its `deviceUUID` is no serial number).
/// Nothing else is compared: no saved identity, one that is the camera's serial
/// number, no reported identity, or a UUID against anything else. A false mismatch
/// would stop a camera that works; a comparison skipped leaves things as they were.
internal enum ONVIFDeviceIdentity {
    enum Comparison: Equatable {
        case same
        case different
        case notCompared(Reason)
    }

    enum Reason: Equatable {
        /// The camera was saved with no device UUID.
        case noSavedIdentity
        /// The saved device UUID is the camera's serial number, or may be one.
        case savedIdentityIsSerialNumber
        /// The device reported no endpoint reference.
        case noReportedIdentity
        /// One is a UUID and the other isn't.
        case differentKinds
    }

    /// Compares the identity a camera was saved with (`savedUUID`, and its serial
    /// number when it was saved apart) with what a device reported: its endpoint
    /// reference and, when asked, its serial number.
    static func compare(
        savedUUID: String?, savedSerialNumber: String?,
        reportedEndpointReference: String?, reportedSerialNumber: String? = nil
    ) -> Comparison {
        let saved: Identity
        switch savedIdentity(uuid: savedUUID, serialNumbers: [savedSerialNumber, reportedSerialNumber]) {
        case .comparable(let identity):
            saved = identity
        case .notComparable(let reason):
            return .notCompared(reason)
        }
        guard let reported = Identity(reportedEndpointReference) else { return .notCompared(.noReportedIdentity) }
        switch (saved, reported) {
        case (.uuid, .uuid), (.text, .text):
            return saved == reported ? .same : .different
        case (.uuid, .text), (.text, .uuid):
            return .notCompared(.differentKinds)
        }
    }

    /// Whether the identity `info` was saved with can be compared with a device's at
    /// all. When it can't, the device isn't asked.
    static func canCompare(_ info: ONVIFSourceInfo) -> Bool {
        if case .comparable = savedIdentity(uuid: info.deviceUUID, serialNumbers: [info.serialNumber]) { return true }
        return false
    }

    // MARK: - Private

    private enum Identity: Equatable {
        case uuid(UUID)
        case text(String)

        init?(_ raw: String?) {
            guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
                return nil
            }
            if text.hasPrefix("urn:") { text.removeFirst(4) }
            if text.hasPrefix("uuid:") { text.removeFirst(5) }
            guard !text.isEmpty else { return nil }
            self = UUID(uuidString: text).map(Self.uuid) ?? .text(text)
        }
    }

    private enum SavedIdentity {
        case comparable(Identity)
        case notComparable(Reason)
    }

    /// `serialNumbers` are serial numbers of the camera: the saved one first, which
    /// says, when there is one, that `uuid` was saved apart from it.
    private static func savedIdentity(uuid: String?, serialNumbers: [String?]) -> SavedIdentity {
        guard let saved = Identity(uuid) else { return .notComparable(.noSavedIdentity) }
        if serialNumbers.compactMap(Identity.init).contains(saved) {
            return .notComparable(.savedIdentityIsSerialNumber)
        }
        if case .text = saved, serialNumbers.first.flatMap(Identity.init) == nil {
            return .notComparable(.savedIdentityIsSerialNumber)
        }
        return .comparable(saved)
    }
}
