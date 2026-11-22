import CoreGraphics
import Foundation
import ImageIO

/// Decodes image bytes to RGBA at exactly the requested size.
///
/// ImageIO rather than AppKit: no NSImage, no main-thread affinity, and the
/// thumbnail path scales during decode instead of after it.
public func decodePixels(_ data: Data, width: Int, height: Int) -> PixelImage? {
    guard width > 0, height > 0,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }

    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress,
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    return PixelImage(width: width, height: height, rgba: bytes)
}

/// Encodes a `PixelImage` back to PNG, for diagnostics — so what hum decoded can
/// be opened and looked at rather than inferred from its own rendering.
public func encodePNG(_ image: PixelImage) -> Data? {
    guard image.width > 0, image.height > 0 else { return nil }
    let bytesPerRow = image.width * 4
    guard let provider = CGDataProvider(data: Data(image.rgba) as CFData),
          let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          )
    else { return nil }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output, "public.png" as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
