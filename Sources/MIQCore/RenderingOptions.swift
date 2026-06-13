import Foundation

/// Knobs that change the pixel output of `MIQVolume` slice extraction.
/// Owned by callers (the QL extension reads them from `MIQConfig`); MIQCore
/// itself never touches `UserDefaults`.
public struct RenderingOptions: Sendable, Hashable {
    public let lowerPercentile: Double
    public let upperPercentile: Double
    public let orientation: ViewOrientation
    public let segmentationColoring: SegmentationColoring

    public init(
        lowerPercentile: Double,
        upperPercentile: Double,
        orientation: ViewOrientation = .stored,
        segmentationColoring: SegmentationColoring = .off
    ) {
        self.lowerPercentile = lowerPercentile
        self.upperPercentile = upperPercentile
        self.orientation = orientation
        self.segmentationColoring = segmentationColoring
    }
}
