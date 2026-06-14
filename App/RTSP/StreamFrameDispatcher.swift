import CoreGraphics
import CoreVideo
import Foundation
import os

/// Thread-safe decoded-frame ingress for the RTSP pipeline. It keeps the hot
/// media path off the main actor while using explicit main-actor callbacks for
/// preview UI state.
internal final class StreamFrameDispatcher: Sendable {
    private let jitterBuffer: JitterBuffer
    private let previewRenderer: PreviewFrameRenderer
    private let previewEnabled = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let updatePreviewFPS: @MainActor @Sendable (Int) -> Void
    private let updatePreviewImage: @MainActor @Sendable (CGImage) -> Void

    init(
        model: LemurCamModel,
        previewRenderer: PreviewFrameRenderer = PreviewFrameRenderer(),
        updatePreviewFPS: @escaping @MainActor @Sendable (Int) -> Void,
        updatePreviewImage: @escaping @MainActor @Sendable (CGImage) -> Void
    ) {
        let frameWriter = VirtualCameraFrameWriter(model: model)
        self.jitterBuffer = JitterBuffer { pixelBuffer in
            frameWriter.write(pixelBuffer)
        }
        self.previewRenderer = previewRenderer
        self.updatePreviewFPS = updatePreviewFPS
        self.updatePreviewImage = updatePreviewImage
    }

    func setPreviewEnabled(_ enabled: Bool) {
        previewEnabled.withLock {
            $0 = enabled
        }
    }

    func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        jitterBuffer.enqueue(pixelBuffer)
        previewRenderer.process(
            pixelBuffer,
            previewEnabled: isPreviewEnabled,
            updateFPS: updatePreviewFPS,
            updateImage: updatePreviewImage
        )
    }

    func reset() {
        jitterBuffer.reset()
    }

    private var isPreviewEnabled: Bool {
        previewEnabled.withLock { $0 }
    }
}
