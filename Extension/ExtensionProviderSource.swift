import CoreMediaIO
import Foundation
import IOKit.audio
import os

internal class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider?

    private var deviceSource: ExtensionDeviceSource?

    // CMIOExtensionProviderSource protocol methods (all are required)

    init(clientQueue: DispatchQueue?) {

        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ExtensionDeviceSource(localizedName: LemurCamConfig.virtualCameraName)

        do {
            guard let provider, let deviceSource, let device = deviceSource.device else {
                fatalError("Failed to unwrap provider or device after creation")
            }
            try provider.addDevice(device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    // swiftlint:disable:next unneeded_throws_rethrows
    func connect(to _: CMIOExtensionClient) throws {
        Log.ext.info("Client connected")
    }

    func disconnect(from client: CMIOExtensionClient) {
        Log.ext.info("Client disconnected (pid \(client.pid))")
    }

    var availableProperties: Set<CMIOExtensionProperty> {

        // See full list of CMIOExtensionProperty choices in CMIOExtensionProperties.h
        return [.providerManufacturer]
    }

    // swiftlint:disable unneeded_throws_rethrows
    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {

        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Anees Iqbal"
        }
        return providerProperties
    }
    // swiftlint:enable unneeded_throws_rethrows

    // swiftlint:disable:next unneeded_throws_rethrows
    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {

        // Handle settable properties here.
    }
}
