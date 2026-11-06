import SwiftUI

/// What the edit form asks when Fetch Profiles reached a device that is not the
/// camera being edited (`ONVIFDeviceIdentity`): whether to use it for the camera. Use
/// takes the fetched profiles and the device's identity, which Save stores; Cancel
/// keeps the camera as it was saved. Connecting refuses such a device
/// (`ONVIFError.differentDevice`) until the user has answered here.
internal struct DeviceIdentityPrompt: Identifiable {
    let cameraName: String
    let address: SourceFormONVIFAddressEdits.Address
    /// What the device sent, used only on Use.
    let fetched: ONVIFDeviceDetails
    /// The ticket of the fetch. Use does nothing for a fetch made stale since.
    let ticket: Int

    var id: Int { ticket }

    var title: String {
        "Use this device for \(cameraName)?"
    }

    var message: String {
        "The device at \(address.host) is not the one saved as \(cameraName). "
            + "Use it if you replaced the camera; otherwise check the address."
    }

    /// What the form shows under the fetch while the question is open, and after
    /// Cancel. Use clears it.
    var notUsedMessage: String {
        "A different device answered at \(address.host), so its profiles weren't used."
    }
}

extension View {
    /// Shows `prompt` while it is set, with Use, which calls `onUse`, and Cancel, which
    /// calls `onCancel`. Either answer clears it.
    func deviceIdentityDialog(
        _ prompt: Binding<DeviceIdentityPrompt?>,
        onUse: @escaping (DeviceIdentityPrompt) -> Void,
        onCancel: @escaping (DeviceIdentityPrompt) -> Void
    ) -> some View {
        confirmationDialog(
            prompt.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: prompt.wrappedValue
        ) { shown in
            Button("Use") { onUse(shown) }
            Button("Cancel", role: .cancel) { onCancel(shown) }
        } message: { shown in
            Text(shown.message)
        }
    }
}
