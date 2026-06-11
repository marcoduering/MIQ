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

    // Source-column index per output column, computed once instead of per pixel.
    // The float expression is identical to the previous scalar path, so the
    // chosen source index — and the output bytes — are bit-identical.
    var sxLUT = [Int](repeating: 0, count: targetWidth)
    for nx in 0..<targetWidth {
        sxLUT[nx] = min(width - 1, Int(Float(nx) * Float(width) / Float(targetWidth)))
    }

    pixels.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            sxLUT.withUnsafeBufferPointer { sx in
                var dstBase = 0
                for ny in 0..<targetHeight {
                    // syIdx depends only on the row — hoisted out of the column loop.
                    let syIdx = min(height - 1, Int(Float(ny) * Float(height) / Float(targetHeight)))
                    let rowBase = syIdx * width
                    switch channels {
                    case 1:
                        for nx in 0..<targetWidth {
                            dst[dstBase] = src[rowBase + sx[nx]]
                            dstBase += 1
                        }
                    case 3:
                        for nx in 0..<targetWidth {
                            let s = (rowBase + sx[nx]) * 3
                            dst[dstBase] = src[s]
                            dst[dstBase + 1] = src[s + 1]
                            dst[dstBase + 2] = src[s + 2]
                            dstBase += 3
                        }
                    default:
                        for nx in 0..<targetWidth {
                            let s = (rowBase + sx[nx]) * channels
                            for c in 0..<channels {
                                dst[dstBase + c] = src[s + c]
                            }
                            dstBase += channels
                        }
                    }
                }
            }
        }
    }
    return out
}
