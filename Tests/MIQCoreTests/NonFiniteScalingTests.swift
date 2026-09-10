import Foundation
import Testing
@testable import MIQCore

/// Non-finite `scl_slope` / `scl_inter`. Not corrupt-header coverage: NaN is
/// nibabel's marker for "scaling undefined", so these are ordinary files and must
/// preview normally rather than as a black square (see `normalizedScaling`).
///
/// Both halves are pinned throughout — every test that a non-finite pair is
/// neutralised has a neighbour that the finite pair it must leave alone survives.
/// Otherwise a normaliser that started eating legitimate scaling would pass.
struct NonFiniteScalingTests {
    private static let dim = 4
    /// `makeNii` fills uint8 payloads from `sampleValue`, whose voxel 0 is 0 —
    /// useless for detecting a scaling slip. Voxel 1 is not.
    private static let probeX = 1

    private static func patch<T>(_ data: inout Data, at offset: Int, _ value: T) {
        withUnsafeBytes(of: value) { raw in
            data.replaceSubrange(offset..<(offset + raw.count), with: raw)
        }
    }

    private func nifti1(slope: Float, inter: Float) throws -> MIQImage {
        var data = TestMIQFactory.makeNii(width: Self.dim, height: Self.dim, depth: Self.dim, datatype: .uint8)
        Self.patch(&data, at: 112, slope)
        Self.patch(&data, at: 116, inter)
        return try MIQParser().parseNifti(data)
    }

    private func nifti2(slope: Double, inter: Double) throws -> MIQImage {
        var data = TestMIQFactory.makeNii2(width: Self.dim, height: Self.dim, depth: Self.dim, datatype: .uint8)
        Self.patch(&data, at: 176, slope)
        Self.patch(&data, at: 184, inter)
        return try MIQParser().parseNifti(data)
    }

    private func mif(scaling: String?) throws -> MIQImage {
        try MIQParser().parseMif(TestMIQFactory.makeMif(
            width: Self.dim, height: Self.dim, depth: Self.dim, datatype: .uint8, scaling: scaling
        ))
    }

    private func probe(_ image: MIQImage) -> Float {
        MIQVolume(image: image).voxel(x: Self.probeX, y: 0, z: 0)
    }

    // MARK: - NIfTI-1

    @Test(arguments: [
        (Float.nan, Float(0)),          // nibabel's marker for "undefined"
        (Float.infinity, Float(0)),
        (-Float.infinity, Float(0)),
        (Float(2), Float.nan),          // a finite slope is unusable with a NaN intercept
        (Float.nan, Float.nan),
    ])
    func nifti1NonFiniteScalingIsTreatedAsUnscaled(slope: Float, inter: Float) throws {
        // Must render the stored value, not NaN: `slope != 0` is true for NaN, so
        // every voxel became raw*NaN + inter and the file previewed as black.
        let image = try nifti1(slope: slope, inter: inter)
        #expect(image.header.sclSlope == 0)
        #expect(image.header.sclInter == 0)
        #expect(probe(image) == probe(try nifti1(slope: 0, inter: 0)))
    }

    @Test
    func nifti1FiniteScalingStillApplies() throws {
        let image = try nifti1(slope: 2, inter: 1)
        #expect(image.header.sclSlope == 2)
        #expect(probe(image) == probe(try nifti1(slope: 0, inter: 0)) * 2 + 1)
    }

    @Test
    func nifti1SlopeZeroRemainsUnscaled() throws {
        // The state non-finite scaling normalises INTO must keep behaving as it did,
        // including its disregard for a non-zero intercept.
        #expect(try probe(nifti1(slope: 0, inter: 5)) == probe(try nifti1(slope: 0, inter: 0)))
    }

    @Test
    func nifti1NonFiniteScalingHidesTheScalingRow() throws {
        // Slope 0 also settles the panel: the row is absent, not reading "× nan".
        let rows = MIQMetadata(header: try nifti1(slope: .nan, inter: .nan).header).asDisplayLines()
        #expect(!rows.contains { $0.field == .scaling })
    }

    // MARK: - NIfTI-2 (its own path: different offsets, float64)

    @Test
    func nifti2NonFiniteScalingIsTreatedAsUnscaled() throws {
        let image = try nifti2(slope: .nan, inter: .nan)
        #expect(image.header.sclSlope == 0)
        #expect(probe(image) == probe(try nifti2(slope: 0, inter: 0)))
    }

    @Test
    func nifti2FiniteScalingStillApplies() throws {
        let image = try nifti2(slope: 3, inter: 2)
        #expect(probe(image) == probe(try nifti2(slope: 0, inter: 0)) * 3 + 2)
    }

    // MARK: - MIF (scaling is free text, so "nan" parses)

    @Test
    func mifNonFiniteScalingIsTreatedAsUnscaled() throws {
        let image = try mif(scaling: "nan,nan")
        #expect(image.header.sclSlope == 0)
        #expect(probe(image) == probe(try mif(scaling: nil)))
    }

    @Test
    func mifFiniteScalingStillApplies() throws {
        // MRtrix spells the pair `offset,scale`, so this is scale 2 / offset 1.
        let image = try mif(scaling: "1,2")
        #expect(image.header.sclSlope == 2)
        #expect(image.header.sclInter == 1)
        #expect(probe(image) == probe(try mif(scaling: nil)) * 2 + 1)
    }

    // MARK: - The rendering consequence

    @Test
    func nonFiniteScalingNoLongerBlanksThePreview() throws {
        let preview = MIQVolume(image: try nifti1(slope: .nan, inter: .nan))
            .centerPreview(options: RenderingOptions(lowerPercentile: 2, upperPercentile: 98))
        #expect(preview.windowBounds != nil)
        #expect(Set(preview.slices[.axial]?.pixels ?? []).count > 1)
    }
}
