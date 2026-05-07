import Foundation

public struct GrayscaleImage: Sendable {
    public let width: Int
    public let height: Int
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
    ) -> GrayscaleImage {
        guard pixels.count == width * height,
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
            channels: 1,
            targetWidth: target.width,
            targetHeight: target.height
        )
        return GrayscaleImage(width: target.width, height: target.height, pixels: resampled)
    }
}
