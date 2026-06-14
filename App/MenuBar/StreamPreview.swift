import CoreGraphics
import SwiftUI

@MainActor @Observable
internal final class PreviewStore {
    var latestFrame: CGImage?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var sourceCodec: String?
    var estimatedFPS: Int?
    var isPreviewEnabled: Bool = false {
        didSet {
            if isPreviewEnabled != oldValue { onDemandChanged?() }
        }
    }

    var onDemandChanged: (() -> Void)?

    func clear() {
        latestFrame = nil
        sourceWidth = nil
        sourceHeight = nil
        sourceCodec = nil
        estimatedFPS = nil
    }
}

internal struct StreamPreview: View {
    let previewStore: PreviewStore

    var body: some View {
        VStack(spacing: 4) {
            previewImage
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if let info = streamInfoText {
                Text(info)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var previewImage: some View {
        if let frame = previewStore.latestFrame {
            Image(decorative: frame, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Text("No Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var streamInfoText: String? {
        var parts: [String] = []
        if let width = previewStore.sourceWidth, let height = previewStore.sourceHeight {
            parts.append("\(width)x\(height)")
        }
        if let codec = previewStore.sourceCodec {
            parts.append(codec)
        }
        if let fps = previewStore.estimatedFPS {
            parts.append("\(fps) fps")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
