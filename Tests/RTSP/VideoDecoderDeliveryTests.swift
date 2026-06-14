import CoreVideo
import Foundation
@testable import LemurCam
import os
import XCTest

/// Locks the delivery gate that keeps a torn-down decoder from leaking late frames.
/// VideoToolbox decodes asynchronously and can run the output handler after the
/// decoder has been torn down during a reconnect or format switch. Before the fix the
/// handler forwarded unconditionally, so a stale decoder could push a frame into the
/// next stream's jitter buffer. The real decode loop needs VideoToolbox and is covered
/// on-device; the delivery gate is pure and tested here.
internal final class VideoDecoderDeliveryTests: XCTestCase {

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    func testDeliversWhileActive() throws {
        let decoder = VideoDecoder()
        let counter = LockedCounter()
        decoder.onDecodedFrame = { _ in counter.increment() }

        decoder.deliverIfActive(try makePixelBuffer())

        XCTAssertEqual(counter.value, 1, "an active decoder must deliver decoded frames")
    }

    /// After `tearDown()` (no session was ever created here, so it just flips the gate),
    /// late frames must be dropped, not forwarded.
    func testSuppressesDeliveryAfterTearDown() throws {
        let decoder = VideoDecoder()
        let counter = LockedCounter()
        decoder.onDecodedFrame = { _ in counter.increment() }
        let frame = try makePixelBuffer()
        decoder.deliverIfActive(frame)

        decoder.tearDown()
        decoder.deliverIfActive(frame)
        decoder.deliverIfActive(frame)

        XCTAssertEqual(counter.value, 1, "frames arriving after teardown must be suppressed")
    }
}

private final class LockedCounter: Sendable {
    private let count = OSAllocatedUnfairLock<Int>(initialState: 0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock {
            $0 += 1
        }
    }
}
