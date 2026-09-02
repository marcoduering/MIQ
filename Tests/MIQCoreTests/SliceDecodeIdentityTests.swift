import Foundation
import Testing
@testable import MIQCore

/// Pins the hot slice decode loop (`MIQVolume.prepareSlice`) to the public
/// `voxel(x:y:z:t:)` accessor, which is its documented correctness reference:
/// the fast path hoists the datatype switch out of the per-voxel loop and reads
/// through one raw pointer, and must stay bit-identical to the reference switch.
///
/// Nothing asserted that directly before. The MGH/MGZ tests check headers only,
/// so no test rendered a pixel of big-endian data, and int8 / uint16 / uint32 /
/// float64 slices were never rendered at all. This is the gate for any future
/// work on that loop.
struct SliceDecodeIdentityTests {

    private static let orientations: [ViewOrientation] = [.stored, .neurological, .radiological]

    /// Every grayscale datatype `TestMIQFactory` can encode. RGB is excluded — it
    /// decodes to pixel triples through a separate branch (covered by
    /// `sliceValuesIsNilForColorVolumes` below).
    private static let grayscaleDatatypes: [MIQDatatype] = [
        .uint8, .int8, .int16, .uint16, .int32, .uint32, .float32, .float64
    ]

    private static func options(_ orientation: ViewOrientation) -> RenderingOptions {
        RenderingOptions(lowerPercentile: 2.0, upperPercentile: 98.0, orientation: orientation)
    }

    private static func tempURL(suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-decode-\(UUID().uuidString)\(suffix)")
    }

    /// Walks the decoded slice through the *public* geometry — slice/horizontal/
    /// vertical axes plus the two reversed flags — and compares every element to
    /// `voxel()` by bit pattern, so a NaN or a signed-zero difference cannot slip
    /// through an `==`. Runs all three planes in all three view orientations.
    private func expectDecodeMatchesVoxelAccessor(
        _ volume: MIQVolume,
        label: String,
        volumeIndex: Int = 0
    ) {
        for orientation in Self.orientations {
            let options = Self.options(orientation)
            for plane in SlicePlane.allCases {
                let geometry = volume.sliceGeometry(for: plane, options: options)
                let dims = [volume.width, volume.height, volume.depth]
                let index = dims[geometry.sliceAxis] / 2

                guard let values = volume.sliceValues(
                    plane: plane,
                    index: index,
                    volumeIndex: volumeIndex,
                    options: options
                ) else {
                    Issue.record("\(label): expected a grayscale slice for \(plane) / \(orientation)")
                    continue
                }

                #expect(
                    values.count == geometry.width * geometry.height,
                    "\(label): \(plane) / \(orientation) buffer is \(values.count), expected \(geometry.width * geometry.height)"
                )

                var mismatch: String?
                rows: for row in 0..<geometry.height {
                    for col in 0..<geometry.width {
                        let h = geometry.horizontalReversed ? geometry.width - 1 - col : col
                        let v = geometry.verticalReversed ? geometry.height - 1 - row : row
                        var coord = [0, 0, 0]
                        coord[geometry.sliceAxis] = index
                        coord[geometry.horizontalAxis] = h
                        coord[geometry.verticalAxis] = v

                        let expected = volume.voxel(x: coord[0], y: coord[1], z: coord[2], t: volumeIndex)
                        let actual = values[row * geometry.width + col]
                        if actual.bitPattern != expected.bitPattern {
                            mismatch = """
                            \(label): \(plane) / \(orientation) row \(row) col \(col) \
                            (x:\(coord[0]) y:\(coord[1]) z:\(coord[2]) t:\(volumeIndex)) \
                            decoded \(actual) but voxel() reads \(expected)
                            """
                            break rows
                        }
                    }
                }
                if let mismatch {
                    Issue.record(Comment(rawValue: mismatch))
                }
            }
        }
    }

    @Test
    func niftiSliceDecodeMatchesVoxelAccessorForEveryDatatype() throws {
        for datatype in Self.grayscaleDatatypes {
            // Distinct extents so a transposed axis cannot pass by coincidence.
            let data = TestMIQFactory.makeNii(width: 7, height: 5, depth: 3, datatype: datatype)
            let volume = MIQVolume(image: try MIQParser().parseNifti(data))
            expectDecodeMatchesVoxelAccessor(volume, label: "nii \(datatype)")
        }
    }

    /// Same matrix over MGH, whose payload is big-endian — the byte-swapping arms
    /// of the hoisted reader had no pixel-level coverage at all.
    @Test
    func mghSliceDecodeMatchesVoxelAccessorForBigEndianDatatypes() throws {
        for datatype in [MIQDatatype.uint8, .int16, .int32, .float32] {
            let data = TestMIQFactory.makeMgh(width: 7, height: 5, depth: 3, frames: 1, datatype: datatype)
            let url = Self.tempURL(suffix: ".mgh")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)

            let volume = MIQVolume(image: try MIQParser().parse(url: url))
            #expect(volume.image.header.littleEndian == false)
            expectDecodeMatchesVoxelAccessor(volume, label: "mgh \(datatype)")
        }
    }

    /// A permuted, partly reversed MIF layout: voxel addressing goes through
    /// `payloadElementStrides`, and the reversed axis feeds the orientation frame,
    /// so both the strided read and the axis-label path are in play.
    @Test
    func permutedMifSliceDecodeMatchesVoxelAccessor() throws {
        for datatype in [MIQDatatype.uint8, .int16, .float32] {
            let data = TestMIQFactory.makeMif(
                width: 7,
                height: 5,
                depth: 3,
                datatype: datatype,
                layoutTokens: ["+1", "-0", "+2"]
            )
            let url = Self.tempURL(suffix: ".mif")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)

            let image = try MIQParser().parse(url: url)
            #expect(image.payloadElementStrides != nil)
            expectDecodeMatchesVoxelAccessor(MIQVolume(image: image), label: "mif \(datatype)")
        }
    }

    /// NRRD with the non-spatial axis first, which forces custom strides, and two
    /// timepoints so a non-zero `volumeIndex` also crosses the strided path.
    @Test
    func stridedNrrdSliceDecodeMatchesVoxelAccessor() throws {
        for datatype in [MIQDatatype.uint8, .int16, .float64] {
            let data = TestMIQFactory.makeNrrdWithLeadingListAxis(
                volumes: 2,
                width: 7,
                height: 5,
                depth: 3,
                datatype: datatype
            )
            let url = Self.tempURL(suffix: ".nrrd")
            defer { try? FileManager.default.removeItem(at: url) }
            try data.write(to: url)

            let image = try MIQParser().parse(url: url)
            #expect(image.payloadElementStrides != nil)
            #expect(image.header.volumes == 2)

            let volume = MIQVolume(image: image)
            expectDecodeMatchesVoxelAccessor(volume, label: "nrrd \(datatype) t0", volumeIndex: 0)
            expectDecodeMatchesVoxelAccessor(volume, label: "nrrd \(datatype) t1", volumeIndex: 1)
        }
    }

    /// A NIfTI whose sform permutes the storage axes (x→S, y→R, z→A), so the three
    /// view modes produce genuinely different slice/horizontal/vertical assignments
    /// rather than three variations of the stored order.
    @Test
    func permutedSformSliceDecodeMatchesVoxelAccessor() throws {
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 7,
            height: 5,
            depth: 3,
            datatype: .int16,
            sformCode: 1,
            srowX: [0, 1, 0, 0],
            srowY: [0, 0, 1, 0],
            srowZ: [1, 0, 0, 0],
            qformCode: 0,
            quaternB: 0,
            quaternC: 0,
            quaternD: 0,
            qfac: 1
        )
        let image = try MIQParser().parseNifti(data)
        #expect(image.header.orientationFrame != nil)

        let volume = MIQVolume(image: image)
        // The permutation must actually change the plan, or this adds no coverage.
        let stored = volume.sliceGeometry(for: .axial, options: Self.options(.stored))
        let neuro = volume.sliceGeometry(for: .axial, options: Self.options(.neurological))
        #expect(stored.sliceAxis != neuro.sliceAxis)

        expectDecodeMatchesVoxelAccessor(volume, label: "permuted sform nii")
    }

    /// 4D NIfTI: volume 1 must read from the second volume's payload, and an
    /// out-of-range timepoint must decode to zeros — exactly what `voxel()` returns
    /// for the same coordinates.
    @Test
    func fourDNiftiSliceDecodeMatchesVoxelAccessorIncludingOutOfRangeVolume() throws {
        let data = TestMIQFactory.makeNii(width: 7, height: 5, depth: 3, datatype: .int16, volumes: 2)
        let volume = MIQVolume(image: try MIQParser().parseNifti(data))

        expectDecodeMatchesVoxelAccessor(volume, label: "4D nii t1", volumeIndex: 1)
        expectDecodeMatchesVoxelAccessor(volume, label: "4D nii out-of-range t", volumeIndex: 5)

        let values = try #require(volume.sliceValues(
            plane: .axial,
            index: 1,
            volumeIndex: 5,
            options: Self.options(.stored)
        ))
        #expect(values.allSatisfy { $0 == 0 })
    }

    /// RGB volumes decode to pixel triples, not scalars — the accessor reports that
    /// by returning `nil` rather than a buffer of the wrong meaning.
    @Test
    func sliceValuesIsNilForColorVolumes() throws {
        let data = TestMIQFactory.makeNii(width: 6, height: 4, depth: 3, datatype: .rgb24)
        let volume = MIQVolume(image: try MIQParser().parseNifti(data))

        #expect(volume.sliceValues(plane: .axial, index: 1, options: Self.options(.stored)) == nil)
    }

    /// The accessor clamps an out-of-range slice index the same way `slice(plan:…)`
    /// does, so the comparison walk above is reading the slice it thinks it is.
    @Test
    func sliceValuesClampsOutOfRangeIndex() throws {
        let data = TestMIQFactory.makeNii(width: 7, height: 5, depth: 3, datatype: .uint8)
        let volume = MIQVolume(image: try MIQParser().parseNifti(data))
        let options = Self.options(.stored)

        let last = try #require(volume.sliceValues(plane: .axial, index: 2, options: options))
        let beyond = try #require(volume.sliceValues(plane: .axial, index: 99, options: options))
        #expect(last == beyond)
    }
}
