import SwiftUI

internal struct PreviewSettingsView: View {
    let previewStore: PreviewStore?
    @Bindable var sourceManager: SourceManager

    var body: some View {
        VStack(spacing: 0) {
            if let previewStore {
                StreamPreview(previewStore: previewStore)
                    .padding()
            } else {
                Text("No Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding()
            }

            if let previewStore {
                Form {
                    Section {
                        streamInfoRow("Status", value: activeStatusText)
                        if let width = previewStore.sourceWidth, let height = previewStore.sourceHeight {
                            streamInfoRow("Resolution", value: "\(width) × \(height)")
                        }
                        if let codec = previewStore.sourceCodec {
                            streamInfoRow("Codec", value: codec)
                        }
                        if let fps = previewStore.estimatedFPS {
                            streamInfoRow("Frame Rate", value: "\(fps) fps")
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }

            Spacer()
        }
    }

    private var activeStatusText: String {
        guard let activeID = sourceManager.activeSourceID else { return "No Camera Selected" }
        let status = sourceManager.connectionStatuses[activeID] ?? .disconnected
        let sourceName = sourceManager.sources.first(where: { $0.id == activeID })?.name ?? "Unknown"
        return "\(sourceName) — \(connectionStatusLabel(status))"
    }

    private func streamInfoRow(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

}
