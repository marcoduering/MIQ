import Foundation
import Testing
@testable import MIQCore

/// `nearestNeighborResample` was rewritten to hoist a source-column LUT, lift
/// the row index out of the inner loop, drop bounds checks, and special-case
/// 1/3 channels. The chosen source index uses the identical float expression,
/// so output must stay byte-identical to the naive scalar path.
struct NearestNeighborResampleTests {

    /// The pre-optimization scalar implementation, verbatim — the correctness
    /// reference.
    private static func reference(
        pixels: [UInt8],
        width: Int, height: Int, channels: Int,
        targetWidth: Int, targetHeight: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: targetWidth * targetHeight * channels)
        for ny in 0..<targetHeight {
            for nx in 0..<targetWidth {
                let sxIdx = min(width - 1, Int(Float(nx) * Float(width) / Float(targetWidth)))
                let syIdx = min(height - 1, Int(Float(ny) * Float(height) / Float(targetHeight)))
                let srcBase = (syIdx * width + sxIdx) * channels
                let dstBase = (ny * targetWidth + nx) * channels
                for c in 0..<channels {
                    out[dstBase + c] = pixels[srcBase + c]
                }
            }
        }
        return out
    }

    private static func randomPixels(_ count: Int, seed: UInt64) -> [UInt8] {
        var s = seed
        return (0..<count).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: s >> 33)
        }
    }

    @Test(arguments: [
        // (w, h, tw, th)
        (64, 48, 128, 96),   // upscale
        (128, 96, 64, 48),   // downscale
        (100, 100, 100, 100),// identity dimensions (still exercises the path)
        (77, 33, 51, 120),   // non-uniform, mixed direction
        (512, 512, 384, 384),// realistic preview downscale
    ])
    func matchesScalarReference(dims: (w: Int, h: Int, tw: Int, th: Int)) {
        for channels in [1, 3] {
            let pixels = Self.randomPixels(dims.w * dims.h * channels, seed: 0x1234_5678 &+ UInt64(channels))
            let produced = nearestNeighborResample(
                pixels: pixels, width: dims.w, height: dims.h, channels: channels,
                targetWidth: dims.tw, targetHeight: dims.th
            )
            let expected = Self.reference(
                pixels: pixels, width: dims.w, height: dims.h, channels: channels,
                targetWidth: dims.tw, targetHeight: dims.th
            )
            #expect(produced == expected, "channels=\(channels) dims=\(dims)")
        }
    }
}
