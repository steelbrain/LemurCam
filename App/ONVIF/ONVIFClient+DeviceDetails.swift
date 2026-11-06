/// What the add/edit form and the Discover sheet read from a camera before the user
/// picks a profile.
internal struct ONVIFDeviceDetails: Sendable {
    let profiles: [ONVIFProfile]
    /// nil when the camera did not answer GetDeviceInformation.
    let info: ONVIFDeviceInfo?
    /// nil when it was not asked for, or the camera gave none.
    let endpointReference: String?
}

extension ONVIFClient {
    /// The camera's profiles, then its device information and, when
    /// `includingEndpointReference`, its endpoint reference, one request at a time.
    /// GetProfiles goes first and proves the credentials; the others are sent only
    /// once it succeeded, so a wrong password costs one failed login. Sending
    /// GetDeviceInformation alongside GetProfiles cost two, which counts double
    /// toward the lockout some cameras impose after a few failed logins. The later
    /// requests may fail without failing the fetch: not every camera supports them.
    func fetchDeviceDetails(includingEndpointReference: Bool) async throws -> ONVIFDeviceDetails {
        let profiles = try await getProfiles()
        let info = try? await getDeviceInformation()
        var reference: String?
        if includingEndpointReference {
            reference = try? await getEndpointReference()
        }
        return ONVIFDeviceDetails(profiles: profiles, info: info, endpointReference: reference)
    }
}
