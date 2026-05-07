import Foundation

public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    /// Interleaved RGB bytes — length == width * height * 3.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public func resampledForPixelSpacing(
        pixelSpacingX: Float,
        pixelSpacingY: Float,
        maxPhysicalExtent: Float,
        maxDimension: Int
    ) -> RGBImage {
        guard pixels.count == width * height * 3,
              let target = ResampleTargetSize(
                width: width,
                height: height,
                pixelSpacingX: pixelSpacingX,
                pixelSpacingY: pixelSpacingY,
                maxPhysicalExtent: maxPhysicalExtent,
                maxDimension: maxDimension
              ),
              target.width != width || target.height != height else {
            return self
        }

        let resampled = nearestNeighborResample(
            pixels: pixels,
            width: width,
            height: height,
            channels: 3,
            targetWidth: target.width,
            targetHeight: target.height
        )
        return RGBImage(width: target.width, height: target.height, pixels: resampled)
    }
}
