import AppKit
import MIQCore

enum MIQImageBridge {
    /// Convenience for callers without a pre-expanded bitmap (the thumbnail
    /// provider's one-shot render). The preview model instead expands via
    /// `SliceImage.rgbaBitmap()` inside its detached render task and hands the
    /// MainActor only the bitmap overload below.
    static func makeNSImage(from slice: SliceImage) -> NSImage? {
        slice.rgbaBitmap().flatMap(makeNSImage(from:))
    }

    /// Cheap by design — this is the only part that must run on the MainActor.
    /// The per-pixel expansion already happened in `rgbaBitmap()`, and
    /// `bitmap.pixels as CFData` bridges without copying (the CGImage retains
    /// the buffer through the provider), so no pixel pass happens here.
    static func makeNSImage(from bitmap: RGBABitmap) -> NSImage? {
        guard bitmap.width > 0, bitmap.height > 0,
              bitmap.pixels.count == bitmap.width * bitmap.height * 4,
              let provider = CGDataProvider(data: bitmap.pixels as CFData),
              let cgImage = CGImage(
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}
