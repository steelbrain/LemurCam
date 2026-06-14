import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import os
import QuartzCore

/// Owns preview FPS bookkeeping and preview-image rendering. Decoded frames
/// arrive from the RTSP pipeline, rendering runs on `renderQueue`, and UI writes
/// are explicitly bounced to the main actor through the supplied callbacks.
internal final class PreviewFrameRenderer: Sendable {
    private struct State: Sendable {
        var isRendering = false
        var lastPreviewTime: CFTimeInterval = 0
        var frameTimestamps: [CFTimeInterval] = []
        var lastFPSUpdateTime: CFTimeInterval = 0
    }

    private let context: CIContext
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let renderQueue = DispatchQueue(label: "com.steelbrain.LemurCam.preview", qos: .userInitiated)

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.context = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    }

    func process(
        _ pixelBuffer: CVPixelBuffer,
        previewEnabled: Bool,
        updateFPS: @escaping @MainActor @Sendable (Int) -> Void,
        updateImage: @escaping @MainActor @Sendable (CGImage) -> Void
    ) {
        let now = CACurrentMediaTime()
        let (fps, shouldUpdatePreview) = updateFPSAndCheckPreview(
            now: now, isPreviewEnabled: previewEnabled
        )
        if let fps {
            Task { @MainActor in updateFPS(fps) }
        }
        guard shouldUpdatePreview, markRenderingStarted() else { return }

        let frame = SendablePixelBuffer(pixelBuffer)
        renderQueue.async { [weak self, frame] in
            guard let self else { return }
            let cgImage = frame.withValue {
                Self.downscaledPreviewImage(
                    from: $0, context: self.context, maxHeight: Tuning.previewRenderMaxHeight
                )
            }
            self.markRenderingFinished()
            if let cgImage {
                Task { @MainActor in updateImage(cgImage) }
            }
        }
    }

    /// Downscale factor that keeps a source of `sourceHeight` within `maxHeight`,
    /// never upscaling. Returns 1 when the source already fits, when `maxHeight` is
    /// non-positive, or when `sourceHeight` is not a finite positive number.
    static func previewDownscaleFactor(sourceHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard sourceHeight.isFinite, sourceHeight > maxHeight, maxHeight > 0 else { return 1 }
        return maxHeight / sourceHeight
    }

    /// Render a preview `CGImage` from a decoded frame, downscaled so its height does
    /// not exceed `maxHeight`. Rendering at full source resolution (up to 4K) and then
    /// shrinking in the view wastes a large GPU->CPU readback every preview frame;
    /// downscaling before `createCGImage` shrinks that copy with no visible change at
    /// the preview's display size.
    static func downscaledPreviewImage(
        from pixelBuffer: CVPixelBuffer, context: CIContext, maxHeight: CGFloat
    ) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let factor = previewDownscaleFactor(sourceHeight: ciImage.extent.height, maxHeight: maxHeight)
        let image = factor < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            : ciImage
        return context.createCGImage(image, from: image.extent)
    }

    private func markRenderingStarted() -> Bool {
        state.withLock {
            guard !$0.isRendering else { return false }
            $0.isRendering = true
            return true
        }
    }

    private func markRenderingFinished() {
        state.withLock {
            $0.isRendering = false
        }
    }

    private func updateFPSAndCheckPreview(
        now: CFTimeInterval, isPreviewEnabled: Bool
    ) -> (Int?, Bool) {
        state.withLock {
            $0.frameTimestamps.append(now)
            $0.frameTimestamps.removeAll { now - $0 > Tuning.fpsWindowDuration }

            var fps: Int?
            if now - $0.lastFPSUpdateTime >= Tuning.fpsUpdateInterval,
               $0.frameTimestamps.count >= 2,
               let lastTimestamp = $0.frameTimestamps.last,
               let firstTimestamp = $0.frameTimestamps.first {
                let elapsed = lastTimestamp - firstTimestamp
                if elapsed > 0 { fps = Int(round(Double($0.frameTimestamps.count - 1) / elapsed)) }
                $0.lastFPSUpdateTime = now
            }

            let shouldUpdate = isPreviewEnabled && now - $0.lastPreviewTime >= Tuning.previewThrottleInterval
            if shouldUpdate { $0.lastPreviewTime = now }
            return (fps, shouldUpdate)
        }
    }
}
