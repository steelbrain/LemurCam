import CoreVideo

/// CoreVideo pixel buffers are reference types that Swift does not model as
/// `Sendable`. This wrapper owns a retain count while a frame reference crosses
/// an executor or dispatch-queue boundary, and stores only the retained object's
/// address so Swift can check the wrapper itself.
internal typealias SendablePixelBuffer = SendableRetainedReference<CVPixelBuffer>
