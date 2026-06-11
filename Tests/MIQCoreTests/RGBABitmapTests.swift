import Foundation
import Testing
@testable import MIQCore

/// `SliceImage.rgbaBitmap()` feeds the CGImage the preview displays; its output
/// must stay byte-identical to the expansion the AppKit bridge used to do
/// inline (gray g → [g,g,g,255], rgb → [r,g,b,255]).
struct RGBABitmapTests {

    @Test func grayscaleExpandsToOpaqueRGBA() throws {
        let slice = SliceImage.grayscale(GrayscaleImage(width: 2, height: 2, pixels: [0, 7, 128, 255]))
        let bitmap = try #require(slice.rgbaBitmap())
        #expect(bitmap.width == 2)
        #expect(bitmap.height == 2)
        #expect(bitmap.pixels == Data([
            0, 0, 0, 255,
            7, 7, 7, 255,
            128, 128, 128, 255,
            255, 255, 255, 255,
        ]))
    }

    @Test func rgbExpandsToOpaqueRGBA() throws {
        let slice = SliceImage.rgb(RGBImage(width: 2, height: 1, pixels: [1, 2, 3, 250, 251, 252]))
        let bitmap = try #require(slice.rgbaBitmap())
        #expect(bitmap.width == 2)
        #expect(bitmap.height == 1)
        #expect(bitmap.pixels == Data([
            1, 2, 3, 255,
            250, 251, 252, 255,
        ]))
    }

    @Test func mismatchedBufferReturnsNil() {
        let shortGray = SliceImage.grayscale(GrayscaleImage(width: 2, height: 2, pixels: [1, 2, 3]))
        #expect(shortGray.rgbaBitmap() == nil)
        let shortRGB = SliceImage.rgb(RGBImage(width: 2, height: 1, pixels: [1, 2, 3]))
        #expect(shortRGB.rgbaBitmap() == nil)
    }

    @Test func degenerateDimensionsReturnNil() {
        let empty = SliceImage.grayscale(GrayscaleImage(width: 0, height: 0, pixels: []))
        #expect(empty.rgbaBitmap() == nil)
    }

    /// Pseudo-random full-size buffers against a literal reimplementation of the
    /// legacy bridge expansion — the bit-identical contract at realistic scale.
    @Test func matchesLegacyExpansionOnFullSizeSlices() throws {
        let side = 512
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }

        let grayPixels = (0..<(side * side)).map { _ in next() }
        let gray = SliceImage.grayscale(GrayscaleImage(width: side, height: side, pixels: grayPixels))
        #expect(try #require(gray.rgbaBitmap()).pixels == Self.legacyExpansion(gray))

        let rgbPixels = (0..<(side * side * 3)).map { _ in next() }
        let rgb = SliceImage.rgb(RGBImage(width: side, height: side, pixels: rgbPixels))
        #expect(try #require(rgb.rgbaBitmap()).pixels == Self.legacyExpansion(rgb))
    }

    /// The exact per-render expansion `MIQImageBridge` performed before the
    /// single-pass `rgbaBitmap()` replaced it (RGBA array build + `Data(array)`
    /// copy). Kept as the correctness reference; also timed by
    /// `PerformanceBaselineTests.rgbaBridgeExpansion`.
    static func legacyExpansion(_ slice: SliceImage) -> Data {
        switch slice {
        case .grayscale(let gray):
            var rgba = [UInt8](repeating: 255, count: gray.width * gray.height * 4)
            for i in 0..<(gray.width * gray.height) {
                let g = gray.pixels[i]
                let j = i * 4
                rgba[j] = g
                rgba[j + 1] = g
                rgba[j + 2] = g
            }
            return Data(rgba)
        case .rgb(let rgb):
            var rgba = [UInt8](repeating: 255, count: rgb.width * rgb.height * 4)
            for i in 0..<(rgb.width * rgb.height) {
                let src = i * 3
                let dst = i * 4
                rgba[dst] = rgb.pixels[src]
                rgba[dst + 1] = rgb.pixels[src + 1]
                rgba[dst + 2] = rgb.pixels[src + 2]
            }
            return Data(rgba)
        }
    }
}
