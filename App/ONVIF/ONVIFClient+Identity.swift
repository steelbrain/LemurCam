extension ONVIFClient {
    /// Checks that the device at the client's address is the camera saved as `info`,
    /// before anything signed goes to it. After a DHCP change another camera can answer
    /// at the saved address: the stream then came from the wrong camera, and it got the
    /// saved login. The resolve then looks for the camera elsewhere
    /// (`ONVIFRediscovery.shouldRediscover`).
    ///
    /// Asks GetEndpointReference once, unsigned, so no credentials go along, and only
    /// when the saved identity can be compared (`ONVIFDeviceIdentity.canCompare`).
    /// Throws `ONVIFError.differentDevice` when the device reports another identity. A
    /// device that can't be reached, or one whose certificate or address is refused,
    /// throws as any request would (`ONVIFError.failsEveryRequest`). Any other answer
    /// (a SOAP fault, an HTTP error, a login required, a reply without a GUID) leaves
    /// the identity unchecked: not every camera answers the call, or answers it
    /// without a login.
    func checkIdentity(of info: ONVIFSourceInfo) async throws {
        guard ONVIFDeviceIdentity.canCompare(info) else { return }
        let reported: String?
        do {
            reported = try await getEndpointReference(signed: false)
        } catch let error as ONVIFError where error.failsEveryRequest {
            throw error
        } catch {
            Log.rtsp.info("Not checking which device answers at \(info.host): \(error.localizedDescription)")
            return
        }
        let comparison = ONVIFDeviceIdentity.compare(
            savedUUID: info.deviceUUID, savedSerialNumber: info.serialNumber, reportedEndpointReference: reported
        )
        switch comparison {
        case .same:
            return
        case .different:
            Log.rtsp.warning("A different device answers at \(info.host); not connecting")
            throw ONVIFError.differentDevice(host: info.host)
        case .notCompared(let reason):
            Log.rtsp.info("Not checking which device answers at \(info.host): \(reason)")
        }
    }
}
