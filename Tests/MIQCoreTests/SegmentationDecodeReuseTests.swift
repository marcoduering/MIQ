import Foundation
import Testing
@testable import MIQCore

/// Item 6 removed the duplicate center-slice decode: `centerPreview` and
/// `centerInteractiveState` now detect the segmentation LUT from the slices they
/// already decoded rather than re-decoding via `buildSegmentationLut(options:)`.
/// These pin the reused-decode result identical to the self-decoding reference.
struct SegmentationDecodeReuseTests {

    private static let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)

    private static func labelVolume(_ labels: [Int]) throws -> MIQVolume {
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: labels)
        return MIQVolume(image: try MIQParser().parseNifti(data))
    }

    @Test func centerPreviewLutMatchesSelfDecodingForFreeSurfer() throws {
        let volume = try Self.labelVolume([0, 2, 3, 41, 42, 10, 11, 17, 251])
        let reference = try #require(volume.buildSegmentationLut(options: Self.autoOptions))
        let preview = try #require(volume.centerPreview(options: Self.autoOptions).segmentationLut)
        #expect(preview.kind == reference.kind)
    }

    @Test func centerPreviewLutMatchesSelfDecodingForRandomPalette() throws {
        let volume = try Self.labelVolume([0, 1, 2, 3])
        let reference = try #require(volume.buildSegmentationLut(options: Self.autoOptions))
        let preview = try #require(volume.centerPreview(options: Self.autoOptions).segmentationLut)
        #expect(preview.kind == reference.kind)
        #expect(preview.kind == .random)
    }

    @Test func centerInteractiveStateMatchesSeparateCalls() throws {
        let volume = try Self.labelVolume([0, 1, 2, 3])
        let combined = volume.centerInteractiveState(options: Self.autoOptions)
        let referenceLut = volume.buildSegmentationLut(options: Self.autoOptions)
        // LUT active ⇒ identical kind, and windowing replaced (nil bounds).
        #expect(combined.segmentationLut?.kind == referenceLut?.kind)
        #expect(referenceLut != nil)
        #expect(combined.windowBounds == nil)
    }

    @Test func centerInteractiveStateWindowMatchesFixedCenterWindowWhenNoLut() throws {
        // A genuine intensity image (no labels): no LUT, so the combined helper's
        // window must equal `fixedCenterWindow` exactly.
        let data = TestMIQFactory.makeNii(width: 16, height: 16, depth: 16, datatype: .int16)
        let volume = MIQVolume(image: try MIQParser().parseNifti(data))
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        let combined = volume.centerInteractiveState(options: options)
        let reference = volume.fixedCenterWindow(volumeIndex: 0, options: options)
        #expect(combined.segmentationLut == nil)
        switch (combined.windowBounds, reference) {
        case (nil, nil):
            break
        case let (c?, r?):
            #expect(c.low.bitPattern == r.low.bitPattern)
            #expect(c.high.bitPattern == r.high.bitPattern)
        default:
            Issue.record("window-bounds nil mismatch")
        }
    }

    @Test func offModeDecodesNothingAndYieldsWindowOnly() throws {
        let volume = try Self.labelVolume([0, 1, 2, 3])
        let off = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .off)
        let combined = volume.centerInteractiveState(options: off)
        #expect(combined.segmentationLut == nil)
        // Window still derived from the same decode.
        #expect(combined.windowBounds != nil)
    }
}
