import Foundation
import Testing
@testable import MIQCore

/// Foreground that misses all three center planes (a lesion or single-ROI mask
/// often does). The center sample is then pure background, so segmentation
/// detection and the intensity window must fall back to the whole volume —
/// before, both were derived from zeros and every slice rendered black.
struct OffCenterForegroundTests {

    private static let auto = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
    private static let off = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .off)

    // 16³: center planes are x = 8, y = 8, z = 8. The corner box never touches them.
    private static let side = 16

    private static func inCorner(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        (2...5).contains(x) && (2...5).contains(y) && (2...5).contains(z)
    }

    private static func inFarCorner(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        (11...13).contains(x) && (11...13).contains(y) && (11...13).contains(z)
    }

    /// A little-endian NIfTI volume whose voxel (x, y, z, t) holds `value`.
    private static func makeVolume(
        datatype: MIQDatatype = .int16,
        volumes: Int = 1,
        value: (Int, Int, Int, Int) -> Float
    ) throws -> MIQVolume {
        var data = TestMIQFactory.makeNii(
            width: side, height: side, depth: side, datatype: datatype, volumes: volumes
        )
        let voxOffset = 352
        var index = 0
        for t in 0..<volumes {
            for z in 0..<side {
                for y in 0..<side {
                    for x in 0..<side {
                        let v = value(x, y, z, t)
                        let offset = voxOffset + index * datatype.bytesPerVoxel
                        switch datatype {
                        case .int16:
                            withUnsafeBytes(of: Int16(v).littleEndian) { data.replaceSubrange(offset..<offset + 2, with: $0) }
                        case .float32:
                            withUnsafeBytes(of: v.bitPattern.littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) }
                        default:
                            Issue.record("unsupported fixture datatype \(datatype)")
                        }
                        index += 1
                    }
                }
            }
        }
        return MIQVolume(image: try MIQParser().parseNifti(data))
    }

    // MARK: - Segmentation detection

    @Test
    func offCenterBinaryMaskIsMonochromeWhite() throws {
        let volume = try Self.makeVolume { x, y, z, _ in Self.inCorner(x, y, z) ? 1 : 0 }
        #expect(volume.buildSegmentationLut(options: Self.auto)?.kind == .monochromeWhite)
        // The single-decode paths the preview uses must agree.
        #expect(volume.centerPreview(options: Self.auto).segmentationLut?.kind == .monochromeWhite)
        let state = volume.centerInteractiveState(options: Self.auto)
        #expect(state.segmentationLut?.kind == .monochromeWhite)
        #expect(state.windowBounds == nil)
    }

    @Test
    func offCenterMultiLabelGetsColourLut() throws {
        let volume = try Self.makeVolume { x, y, z, _ in
            if Self.inCorner(x, y, z) { return 3 }
            return Self.inFarCorner(x, y, z) ? 7 : 0
        }
        let lut = try #require(volume.buildSegmentationLut(options: Self.auto))
        #expect(lut.kind == .random)
        // Both labels are in the ranked palette, so they get distinct colours.
        let a = lut.lookup(3), b = lut.lookup(7)
        #expect((a.r, a.g, a.b) != (b.r, b.g, b.b))
    }

    @Test
    func offCenterIntegerIntensityIsNotColoured() throws {
        // Integral values off center, but noisy rather than piecewise constant —
        // the whole-volume scan must keep the piecewise-constancy gate.
        var state: UInt32 = 12345
        let volume = try Self.makeVolume { x, y, z, _ in
            guard x < 8, y < 8, z < 8 else { return 0 }
            state = state &* 1_103_515_245 &+ 12345
            return Float(1 + (state >> 16) % 200)
        }
        #expect(volume.buildSegmentationLut(options: Self.auto) == nil)
        // Falls through to a real window instead of a black one.
        let window = try #require(volume.centerInteractiveState(options: Self.auto).windowBounds)
        #expect(window.high > window.low)
    }

    @Test
    func centerLabelVolumeDoesNotChange() throws {
        // A mask that crosses the center planes keeps its pre-existing verdict.
        let volume = try Self.makeVolume { x, y, z, _ in
            (6...10).contains(x) && (6...10).contains(y) && (6...10).contains(z) ? 4 : 0
        }
        #expect(volume.buildSegmentationLut(options: Self.auto)?.kind == .monochromeWhite)
    }

    // MARK: - Intensity window

    @Test
    func offCenterMaskWindowSpansBackgroundToLabel() throws {
        let volume = try Self.makeVolume { x, y, z, _ in Self.inCorner(x, y, z) ? 1 : 0 }
        let state = volume.centerInteractiveState(options: Self.off)
        #expect(state.segmentationLut == nil)
        let window = try #require(state.windowBounds)
        #expect(window.low == 0)
        #expect(window.high == 1)
        #expect(volume.fixedCenterWindow(options: Self.off) == window)
        #expect(volume.centerPreview(options: Self.off).windowBounds == window)

        // Scrolled onto the mask, its voxels are visible, not black.
        guard case .grayscale(let image) = volume.slice(
            plane: .axial, index: 3, options: Self.off, windowBounds: window
        ) else {
            Issue.record("expected a grayscale slice")
            return
        }
        #expect(image.pixels.contains(255))
    }

    @Test
    func constantNonZeroCenterWidensToVolumeRange() throws {
        // Center planes all 100; the rest of the volume holds other values.
        let volume = try Self.makeVolume { x, y, z, _ in
            if x == 8 || y == 8 || z == 8 { return 100 }
            return Self.inCorner(x, y, z) ? 300 : 100
        }
        let window = try #require(volume.centerInteractiveState(options: Self.off).windowBounds)
        #expect(window.low == 100)
        #expect(window.high == 300)
    }

    @Test
    func nonFiniteCenterFallsBackToFiniteVoxelsElsewhere() throws {
        // Center planes NaN: previously no window at all (the "no finite voxels"
        // message) although volume 0 has data.
        let volume = try Self.makeVolume(datatype: .float32) { x, y, z, _ in
            if x == 8 || y == 8 || z == 8 { return .nan }
            return Self.inCorner(x, y, z) ? 2.5 : 0.5
        }
        let window = try #require(volume.centerInteractiveState(options: Self.off).windowBounds)
        #expect(window.low == 0.5)
        #expect(window.high == 2.5)
    }

    @Test
    func allZeroVolumeStaysDegenerate() throws {
        let volume = try Self.makeVolume { _, _, _, _ in 0 }
        #expect(volume.buildSegmentationLut(options: Self.auto) == nil)
        let window = try #require(volume.centerInteractiveState(options: Self.off).windowBounds)
        #expect(window.low == 0)
        #expect(window.high == 0)
    }

    @Test
    func perVolumeWindowFallsBackWithinItsOwnTimepoint() throws {
        // Volume 0: ordinary data at the center. Volume 1: off-center mask of 9.
        let volume = try Self.makeVolume(volumes: 2) { x, y, z, t in
            if t == 0 { return Float((x + y + z) % 5 + 1) }
            return Self.inCorner(x, y, z) ? 9 : 0
        }
        let window = try #require(volume.fixedCenterWindow(volumeIndex: 1, options: Self.off))
        #expect(window.low == 0)
        #expect(window.high == 9)
    }
}
