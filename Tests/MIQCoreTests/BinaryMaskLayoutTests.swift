import Foundation
import Testing
@testable import MIQCore

/// `confirmBinaryMask` scans volume 0 contiguously whenever it is the first `W·H·D`
/// payload elements in *any* order, not only when `payloadElementStrides` is `nil`.
/// The MIF parser always sets strides, so keying off `nil` sent every MIF mask down
/// the per-voxel walk. These pin that dense MIF layouts take the fast path with the
/// same verdict, and that a volume-interleaved layout still does not.
struct BinaryMaskLayoutTests {

    private static let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)

    // Distinct sizes so a stride mix-up can't cancel out. The box covers all three
    // center planes (x = 6, y = 5, z = 4); voxel (0,0,0) lies on none of them.
    private static let dims = [12, 10, 8]

    private static func inBox(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        (3..<9).contains(x) && (3..<7).contains(y) && (2..<6).contains(z)
    }

    /// A uint8 MIF whose voxel (x, y, z, t) holds `value(x, y, z, t)`, stored in the
    /// given signed layout (MRtrix order ranks; negative = reversed).
    private static func makeMif(
        dims: [Int],
        layout: [Int],
        value: (Int, Int, Int, Int) -> UInt8
    ) throws -> MIQVolume {
        let axisLayout = try MIFAxisLayout(dim: dims, layout: layout)
        let strides = axisLayout.rawStrides
        let volumes = dims.count > 3 ? dims[3] : 1
        var payload = [UInt8](repeating: 0, count: dims.reduce(1, *))
        for t in 0..<volumes {
            for z in 0..<dims[2] {
                for y in 0..<dims[1] {
                    for x in 0..<dims[0] {
                        var index = axisLayout.baseElementIndex + x * strides[0] + y * strides[1] + z * strides[2]
                        if dims.count > 3 { index += t * strides[3] }
                        payload[index] = value(x, y, z, t)
                    }
                }
            }
        }

        let dimLine = dims.map(String.init).joined(separator: ",")
        let voxLine = dims.map { _ in "1.0" }.joined(separator: ",")
        let layoutLine = layout.map { $0 < 0 ? "\($0)" : "+\($0)" }.joined(separator: ",")
        var offset = 0
        var header = ""
        while true {
            header = """
mrtrix image
dim: \(dimLine)
vox: \(voxLine)
layout: \(layoutLine)
datatype: UInt8
file: . \(offset)
END

"""
            let newOffset = header.utf8.count
            if newOffset == offset { break }
            offset = newOffset
        }
        return MIQVolume(image: try MIQParser().parseMif(Data(header.utf8) + Data(payload)))
    }

    @Test(arguments: [[0, 1, 2], [2, 0, 1], [-1, 2, 0], [1, 0, -2]])
    func denseMifMaskTakesContiguousScan(layout: [Int]) throws {
        let mask = try Self.makeMif(dims: Self.dims, layout: layout) { x, y, z, _ in
            Self.inBox(x, y, z) ? 5 : 0
        }
        #expect(mask.volumeZeroIsContiguous)
        #expect(mask.buildSegmentationLut(options: Self.autoOptions)?.kind == .monochromeWhite)

        // A second label off the center planes must still be found by the full scan.
        let twoLabels = try Self.makeMif(dims: Self.dims, layout: layout) { x, y, z, _ in
            if x == 0, y == 0, z == 0 { return 7 }
            return Self.inBox(x, y, z) ? 5 : 0
        }
        #expect(twoLabels.buildSegmentationLut(options: Self.autoOptions)?.kind == .random)
    }

    @Test
    func volumeSlowest4DMifScansOnlyVolumeZero() throws {
        // Volume 0 is a clean mask; volume 1 carries another label. The contiguous
        // scan stops at W·H·D elements, so volume 1 must not leak into the verdict.
        let volume = try Self.makeMif(dims: Self.dims + [2], layout: [0, 1, 2, 3]) { x, y, z, t in
            guard Self.inBox(x, y, z) else { return 0 }
            return t == 0 ? 5 : 9
        }
        #expect(volume.volumeZeroIsContiguous)
        #expect(volume.buildSegmentationLut(options: Self.autoOptions)?.kind == .monochromeWhite)
    }

    @Test
    func volumeFastest4DMifFallsBackToPerVoxelWalk() throws {
        // DWI-style layout: the volume axis varies fastest, so the first W·H·D
        // elements interleave both timepoints. A contiguous scan would see volume
        // 1's label and misreport a multi-label volume.
        let volume = try Self.makeMif(dims: Self.dims + [2], layout: [1, 2, 3, 0]) { x, y, z, t in
            guard Self.inBox(x, y, z) else { return 0 }
            return t == 0 ? 5 : 9
        }
        #expect(!volume.volumeZeroIsContiguous)
        #expect(volume.buildSegmentationLut(options: Self.autoOptions)?.kind == .monochromeWhite)
    }

    // MARK: - Foreground off every center plane

    /// Misses all three center planes (x = 6, y = 5, z = 4), so detection and the
    /// window must walk the whole volume in storage order.
    private static func inOffCenterBox(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        (0..<3).contains(x) && (0..<3).contains(y) && (0..<2).contains(z)
    }

    private static let offOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .off)

    @Test(arguments: [[0, 1, 2], [2, 0, 1], [-1, 2, 0], [1, 0, -2]])
    func offCenterMifMaskScansDenseLayouts(layout: [Int]) throws {
        let mask = try Self.makeMif(dims: Self.dims, layout: layout) { x, y, z, _ in
            Self.inOffCenterBox(x, y, z) ? 5 : 0
        }
        #expect(mask.buildSegmentationLut(options: Self.autoOptions)?.kind == .monochromeWhite)
        #expect(mask.fixedCenterWindow(options: Self.offOptions) == MIQIntensityWindowBounds(low: 0, high: 5))

        let twoLabels = try Self.makeMif(dims: Self.dims, layout: layout) { x, y, z, _ in
            if x == 11, y == 9, z == 7 { return 7 }
            return Self.inOffCenterBox(x, y, z) ? 5 : 0
        }
        #expect(twoLabels.buildSegmentationLut(options: Self.autoOptions)?.kind == .random)
    }

    @Test(arguments: [[0, 1, 2, 3], [1, 2, 3, 0]])
    func offCenter4DMifScansOnlyItsOwnVolume(layout: [Int]) throws {
        // Volume-slowest (contiguous) and volume-fastest (per-voxel walk): volume
        // 1's label must not leak into volume 0's verdict, and each timepoint's
        // window fallback reads that timepoint.
        let volume = try Self.makeMif(dims: Self.dims + [2], layout: layout) { x, y, z, t in
            guard Self.inOffCenterBox(x, y, z) else { return 0 }
            return t == 0 ? 5 : 9
        }
        #expect(volume.buildSegmentationLut(options: Self.autoOptions)?.kind == .monochromeWhite)
        #expect(volume.fixedCenterWindow(volumeIndex: 0, options: Self.offOptions) == MIQIntensityWindowBounds(low: 0, high: 5))
        #expect(volume.fixedCenterWindow(volumeIndex: 1, options: Self.offOptions) == MIQIntensityWindowBounds(low: 0, high: 9))
    }
}
