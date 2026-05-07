import Foundation

/// Pixel spacing → output dimensions for FOV-aware preview resampling.
struct ResampleTargetSize {
    let width: Int
    let height: Int

    init?(
        width: Int,
        height: Int,
        pixelSpacingX: Float,
        pixelSpacingY: Float,
        maxPhysicalExtent: Float,
        maxDimension: Int
    ) {
        guard width > 0, height > 0 else { return nil }
        let sx = max(1e-6, pixelSpacingX)
        let sy = max(1e-6, pixelSpacingY)
        let physicalWidth = Float(width) * sx
        let physicalHeight = Float(height) * sy
        let referencePhysical = max(maxPhysicalExtent, max(physicalWidth, physicalHeight), 1e-6)
        let referencePixels = max(1, maxDimension)
        self.width = max(1, Int((physicalWidth / referencePhysical * Float(referencePixels)).rounded()))
        self.height = max(1, Int((physicalHeight / referencePhysical * Float(referencePixels)).rounded()))
    }
}

/// Nearest-neighbor resample of an interleaved byte buffer with N channels per pixel.
func nearestNeighborResample(
    pixels: [UInt8],
    width: Int,
    height: Int,
    channels: Int,
    targetWidth: Int,
    targetHeight: Int
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
