import CoreGraphics
import CoreVideo
import os

/// Thread-safe decoded-frame ingress for the RTSP pipeline. It keeps the hot
/// media path off the main actor while using explicit main-actor callbacks for
/// preview UI state.
///
/// Only frames from the connection last passed to `accept(_:)` get through. A
/// replaced connection's decoder can still deliver a frame, and its preview
/// render can still land on the main actor, after the switch to another camera;
/// those are dropped so the old camera never reaches the virtual camera or the
/// preview again.
internal final class StreamFrameDispatcher: Sendable {
    private let jitterBuffer: JitterBuffer
    private let previewRenderer: PreviewFrameRenderer
    private let previewEnabled = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Read for every frame on the decoder's thread, so a lock rather than
    /// main-actor state. nil lets no frame through.
    private let acceptedConnection: OSAllocatedUnfairLock<StreamConnectionID?>
    private let updatePreviewFPS: @MainActor @Sendable (Int, StreamConnectionID) -> Void
    private let updatePreviewImage: @MainActor @Sendable (CGImage, StreamConnectionID) -> Void

    init(
        model: LemurCamModel,
        previewRenderer: PreviewFrameRenderer = PreviewFrameRenderer(),
        updatePreviewFPS: @escaping @MainActor @Sendable (Int) -> Void,
        updatePreviewImage: @escaping @MainActor @Sendable (CGImage) -> Void
    ) {
        let frameWriter = VirtualCameraFrameWriter(model: model)
        let accepted = OSAllocatedUnfairLock<StreamConnectionID?>(initialState: nil)
        self.jitterBuffer = JitterBuffer { pixelBuffer in
            frameWriter.write(pixelBuffer)
        }
        self.previewRenderer = previewRenderer
        self.acceptedConnection = accepted
        // A preview update reaches the main actor after its frame was rendered, by
        // when the frame's connection may have been replaced.
        self.updatePreviewFPS = { fps, connection in
            if accepted.withLock({ $0 }) == connection { updatePreviewFPS(fps) }
        }
        self.updatePreviewImage = { image, connection in
            if accepted.withLock({ $0 }) == connection { updatePreviewImage(image) }
        }
    }

    func setPreviewEnabled(_ enabled: Bool) {
        previewEnabled.withLock {
            $0 = enabled
        }
    }

    /// Let through frames from `connection` only, or from none when nil. Call
    /// `reset()` after it to also drop the frames already queued. Another connection
    /// may be another camera, so its frames drain at the default rate until its own
    /// rate is measured (`setSourceFrameRate`): one camera's rate never outlives its
    /// connection, and a rate reported for the new connection can't be undone by a
    /// reset that lands after it.
    func accept(_ connection: StreamConnectionID?) {
        acceptedConnection.withLockUnchecked { accepted in
            guard accepted != connection else { return }
            accepted = connection
            jitterBuffer.setDrainRate(Tuning.jitterBufferDefaultDrainFPS)
        }
    }

    /// Queue a frame from `connection` for the virtual camera and the preview.
    /// Returns false, doing nothing, when `connection` is not the accepted one.
    @discardableResult
    func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer, from connection: StreamConnectionID) -> Bool {
        // Enqueued under the lock, so a frame let through before `accept` switched
        // connections is already queued when the `reset()` after it runs.
        let isAccepted = acceptedConnection.withLockUnchecked { accepted in
            guard accepted == connection else { return false }
            jitterBuffer.enqueue(pixelBuffer)
            return true
        }
        guard isAccepted else { return false }
        previewRenderer.process(
            pixelBuffer,
            from: connection,
            previewEnabled: isPreviewEnabled,
            updateFPS: updatePreviewFPS,
            updateImage: updatePreviewImage
        )
        return true
    }

    /// Drain the frames of `connection` at its camera's frame rate, `fps`. Ignored
    /// when `connection` is not the accepted one: a replaced camera's rate can still
    /// arrive after the switch.
    func setSourceFrameRate(_ fps: Double, from connection: StreamConnectionID) {
        // Under the lock, so it can't land after `accept` switched to another camera.
        acceptedConnection.withLockUnchecked { accepted in
            guard accepted == connection else { return }
            jitterBuffer.setDrainRate(fps)
        }
    }

    func reset() {
        jitterBuffer.reset()
    }

    /// The rate frames are sent on to the virtual camera at.
    var drainRate: Double {
        jitterBuffer.drainRate
    }

    /// Whether decoded frames are being sent on to the virtual camera.
    var isForwardingFrames: Bool {
        jitterBuffer.isDraining
    }

    private var isPreviewEnabled: Bool {
        previewEnabled.withLock { $0 }
    }
}
