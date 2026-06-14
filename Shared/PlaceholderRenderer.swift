import CoreGraphics
import CoreImage
import CoreText
import CoreVideo

internal enum PlaceholderRenderer {
    static func render(
        text: String,
        width: Int,
        height: Int,
        fontSize: CGFloat = 48.0
    ) -> CVPixelBuffer? {
        // CoreGraphics can only draw into an RGB buffer, so render the text into a
        // scratch BGRA buffer and convert it once to NV12 — the format the virtual
        // camera vends. Placeholders render rarely, so the conversion cost is moot.
        guard let rgbBuffer = createPixelBuffer(
            width: width, height: height, format: kCVPixelFormatType_32BGRA
        ) else { return nil }

        CVPixelBufferLockBaseAddress(rgbBuffer, [])
        guard let ctx = createGraphicsContext(buffer: rgbBuffer, width: width, height: height) else {
            CVPixelBufferUnlockBaseAddress(rgbBuffer, [])
            return nil
        }

        ctx.setFillColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText(text, fontSize: fontSize, in: ctx, width: width, height: height)
        CVPixelBufferUnlockBaseAddress(rgbBuffer, [])

        return convertToNV12(rgbBuffer, width: width, height: height)
    }

    private static let sharedCIContext = CIContext()

    private static func createPixelBuffer(
        width: Int, height: Int, format: OSType
    ) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            format, attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        return buffer
    }

    /// Converts a freshly drawn BGRA buffer into an IOSurface-backed NV12 buffer
    /// so the placeholder matches the virtual camera's wire format.
    private static func convertToNV12(
        _ source: CVPixelBuffer, width: Int, height: Int
    ) -> CVPixelBuffer? {
        guard let destination = createPixelBuffer(
            width: width, height: height,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ) else { return nil }
        sharedCIContext.render(CIImage(cvPixelBuffer: source), to: destination)
        return destination
    }

    private static func createGraphicsContext(
        buffer: CVPixelBuffer, width: Int, height: Int
    ) -> CGContext? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private static func drawText(
        _ text: String, fontSize: CGFloat, in ctx: CGContext, width: Int, height: Int
    ) {
        let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, fontSize, nil)
        let textColor = CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: textColor
        ]
        guard let attrString = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes as CFDictionary
        ) else { return }

        let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let midY = CGFloat(height) / 2.0
        let textX = (CGFloat(width) - textBounds.width) / 2.0
        let gap: CGFloat = 20.0

        let normalY = midY + gap / 2.0
        ctx.textPosition = CGPoint(x: textX, y: normalY)
        CTLineDraw(line, ctx)

        let flippedY = midY - gap / 2.0 - textBounds.height
        ctx.saveGState()
        let centerX = CGFloat(width) / 2.0
        ctx.translateBy(x: centerX, y: 0)
        ctx.scaleBy(x: -1.0, y: 1.0)
        ctx.translateBy(x: -centerX, y: 0)
        ctx.textPosition = CGPoint(x: textX, y: flippedY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
