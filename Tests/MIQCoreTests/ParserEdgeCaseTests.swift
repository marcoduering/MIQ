import Foundation
import Testing
@testable import MIQCore

/// The NRRD header ends at its *earliest* blank line. Payload bytes that happen to
/// spell a blank line (`0D 0A 0D 0A`, `0A 0A`) must never be mistaken for it.
struct NrrdHeaderSplitTests {
    /// 4×4×1 uint8, payload bytes 0...15 with the probe bytes spliced in at 4. For
    /// gzip, the probe also goes into the gzip header's FCOMMENT field, which puts it
    /// verbatim into the *compressed* bytes that follow the NRRD header.
    private static func nrrd(
        encoding: String,
        lineEnding: String = "\n",
        splice: [UInt8]
    ) throws -> (data: Data, voxels: [UInt8]) {
        var voxels = (0..<16).map { UInt8($0) }
        voxels.replaceSubrange(4..<(4 + splice.count), with: splice)
        let header = [
            "NRRD0004",
            "type: uint8",
            "dimension: 3",
            "sizes: 4 4 1",
            "encoding: \(encoding)",
        ].joined(separator: lineEnding) + lineEnding + lineEnding
        var payload = Data(voxels)
        if encoding == "gzip" {
            payload = try TestZlib.gzip(payload)
            payload[payload.startIndex + 3] |= 0x10                    // FLG.FCOMMENT
            payload.insert(contentsOf: splice + [0], at: payload.startIndex + 10)
        }
        return (Data(header.utf8) + payload, voxels)
    }

    private static func expectVoxels(_ image: MIQImage, _ voxels: [UInt8]) {
        let volume = MIQVolume(image: image)
        for (i, expected) in voxels.enumerated() {
            #expect(volume.voxel(x: i % 4, y: i / 4, z: 0) == Float(expected))
        }
    }

    @Test
    func rawPayloadContainingCrlfBlankLineSplitsAtHeader() throws {
        let (data, voxels) = try Self.nrrd(encoding: "raw", splice: [0x0D, 0x0A, 0x0D, 0x0A])
        let image = try MIQParser().parseNrrd(data)
        #expect(image.payloadOffset == data.count - voxels.count)
        Self.expectVoxels(image, voxels)
    }

    @Test
    func gzipPayloadContainingCrlfBlankLineSplitsAtHeader() throws {
        // Splitting at the compressed stream's 0D 0A 0D 0A used to fail as
        // "gzip magic bytes are missing".
        let (data, voxels) = try Self.nrrd(encoding: "gzip", splice: [0x0D, 0x0A, 0x0D, 0x0A])
        Self.expectVoxels(try MIQParser().parseNrrd(data), voxels)
    }

    @Test
    func crlfHeaderStillParses() throws {
        let (data, voxels) = try Self.nrrd(encoding: "raw", lineEnding: "\r\n", splice: [0x0A, 0x0A])
        let image = try MIQParser().parseNrrd(data)
        #expect(image.payloadOffset == data.count - voxels.count)
        Self.expectVoxels(image, voxels)
    }

    @Test
    func lfHeaderWithLfBlankLineInPayloadSplitsAtHeader() throws {
        let (data, voxels) = try Self.nrrd(encoding: "raw", splice: [0x0A, 0x0A])
        let image = try MIQParser().parseNrrd(data)
        #expect(image.payloadOffset == data.count - voxels.count)
        Self.expectVoxels(image, voxels)
    }

    @Test
    func missingSeparatorKeepsDetachedHeaderMessage() {
        let data = Data("NRRD0004\ntype: uint8\nsizes: 4 4 1\n".utf8)
        #expect(throws: MIQError.self) { _ = try MIQParser().parseNrrd(data) }
    }
}

/// `avail_in` is a UInt32, so compressed input over 4 GiB is fed in windows. A tiny
/// window exercises every refill without a 4 GiB fixture; chunked input must never
/// change inflate's output.
struct GunzipInputWindowTests {
    private static let raw = TestMIQFactory.makeNii(width: 32, height: 32, depth: 32, datatype: .int16, volumes: 2)

    @Test
    func fullGunzipIsByteIdenticalWithTinyInputWindow() throws {
        let gz = try TestZlib.gzip(Self.raw)
        let windowed = try MIQBinaryReader.gunzip(gz, maxInputWindow: 7)
        #expect(windowed == Self.raw)
        #expect(windowed == (try MIQBinaryReader.gunzip(gz)))
    }

    @Test
    func cappedGunzipIsByteIdenticalWithTinyInputWindow() throws {
        let gz = try TestZlib.gzip(Self.raw)
        // Early stop (cap below the stream size) and full stream (cap covers it).
        for cap in [1 << 15, Self.raw.count, Self.raw.count * 2] {
            let windowed = try MIQBinaryReader.gunzip(gz, maxOutputBytes: cap, maxInputWindow: 7)
            #expect(windowed == (try MIQBinaryReader.gunzip(gz, maxOutputBytes: cap)))
            #expect(windowed == Self.raw.prefix(cap))
        }
    }

    @Test
    func truncationIsDetectedOnlyAfterAllInputIsFed() throws {
        let gz = try TestZlib.gzip(Self.raw)
        let truncated = gz.prefix(gz.count - 64)
        #expect(throws: MIQError.self) { _ = try MIQBinaryReader.gunzip(truncated, maxInputWindow: 7) }
        #expect(throws: MIQError.self) {
            _ = try MIQBinaryReader.gunzip(truncated, maxOutputBytes: Self.raw.count, maxInputWindow: 7)
        }
    }
}

/// `IntensityWindow.apply` used an absolute 1e-6 floor on the window width, which
/// rendered float data spanning less than that (SI-unit ADC maps, ~1e-9) black.
struct IntensityWindowRangeTests {
    /// The previous implementation, verbatim — the reference for windows ≥ 1e-6.
    private static func legacyApply(_ values: [Float], bounds: IntensityWindow.Bounds) -> [UInt8] {
        let range = max(bounds.high - bounds.low, 1e-6)
        return values.map { value in
            guard value.isFinite else { return 0 }
            let clipped = max(bounds.low, min(bounds.high, value))
            let unit = max(0, min(1, (clipped - bounds.low) / range))
            return UInt8((unit * 255).rounded())
        }
    }

    @Test
    func subMicroWindowSpansFullGreyRange() throws {
        let values = (0..<256).map { Float($0) * 2e-9 / 255 }
        let bounds = try #require(IntensityWindow.bounds(for: values, lowerPercentile: 0, upperPercentile: 100))
        let pixels = IntensityWindow.apply(values, bounds: bounds)
        #expect(pixels.first == 0)
        #expect(pixels.last == 255)
        #expect(zip(pixels, pixels.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test
    func normalWindowIsByteIdenticalToLegacy() throws {
        var state: UInt64 = 0x9E3779B97F4A7C15
        let values: [Float] = (0..<4096).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / 1000 - 3000
        } + [.nan, .infinity, -.infinity]
        let bounds = try #require(IntensityWindow.bounds(for: values, lowerPercentile: 2, upperPercentile: 98))
        #expect(IntensityWindow.apply(values, bounds: bounds) == Self.legacyApply(values, bounds: bounds))

        let exactFloor = IntensityWindow.Bounds(low: 0, high: 1e-6)
        let small = (0..<64).map { Float($0) * 1e-6 / 63 }
        #expect(IntensityWindow.apply(small, bounds: exactFloor) == Self.legacyApply(small, bounds: exactFloor))
    }

    @Test
    func degenerateWindowRendersBlack() {
        let bounds = IntensityWindow.Bounds(low: 5, high: 5)
        #expect(IntensityWindow.apply([4, 5, 6], bounds: bounds) == [0, 0, 0])
    }
}

/// NIfTI-2 shares its file kinds with NIfTI-1, whose `displayName` says "NIfTI-1".
struct Nifti2FormatLabelTests {
    @Test
    func nifti2ReportsItsOwnFormat() throws {
        let raw = TestMIQFactory.makeNii2(width: 4, height: 4, depth: 4, datatype: .int16)
        let dir = FileManager.default.temporaryDirectory
        let plainURL = dir.appendingPathComponent("miq-nifti2-\(UUID().uuidString).nii")
        let gzURL = dir.appendingPathComponent("miq-nifti2-\(UUID().uuidString).nii.gz")
        defer {
            try? FileManager.default.removeItem(at: plainURL)
            try? FileManager.default.removeItem(at: gzURL)
        }
        try raw.write(to: plainURL)
        try TestZlib.gzip(raw).write(to: gzURL)

        #expect(try MIQParser().parse(url: plainURL).header.formatLabel == "NIfTI-2")
        #expect(try MIQParser().parse(url: gzURL).header.formatLabel == "Compressed NIfTI-2")
    }

    @Test
    func nifti1KeepsFileKindLabel() throws {
        let raw = TestMIQFactory.makeNii(width: 4, height: 4, depth: 4, datatype: .int16)
        #expect(try MIQParser().parseNifti(raw).header.formatLabel == nil)
    }
}

/// A zero voxel size means "unknown" (viewers treat it as 1), and a non-finite one
/// must not reach the resample arithmetic, where `Int(NaN)` traps.
struct VoxelSpacingTests {
    private static func render(pixdimZ: Float) throws -> [SliceImage] {
        let data = TestMIQFactory.makeNii(width: 8, height: 6, depth: 5, datatype: .int16, pixdim: [1, 1, 1, pixdimZ])
        let volume = MIQVolume(image: try MIQParser().parseNifti(data))
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98)
        return SlicePlane.allCases.map { volume.centerSlice(plane: $0, maxDimension: 64, options: options) }
    }

    private static func pixels(_ image: SliceImage) -> [UInt8] {
        switch image {
        case .grayscale(let img): return img.pixels
        case .rgb(let img): return img.pixels
        }
    }

    @Test
    func zeroSpacingRendersLikeUnitSpacing() throws {
        let zero = try Self.render(pixdimZ: 0)
        let unit = try Self.render(pixdimZ: 1)
        for (a, b) in zip(zero, unit) {
            #expect(a.width == b.width && a.height == b.height)
            #expect(Self.pixels(a) == Self.pixels(b))
        }
    }

    @Test
    func nonFiniteOrOverflowingSpacingDoesNotTrap() throws {
        for pixdimZ in [Float.infinity, -.infinity, .nan, 1e38] {
            for image in try Self.render(pixdimZ: pixdimZ) {
                #expect(image.width >= 1 && image.height >= 1)
            }
        }
    }

    /// A spacing below 1e-6 is valid (finite, positive) and must scale every slice
    /// exactly like the same volume at unit spacing — only the ratios matter.
    @Test
    func subMicroSpacingRendersLikeUnitSpacing() throws {
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98)
        func sizes(pixdim: Float) throws -> [[Int]] {
            let data = TestMIQFactory.makeNii(width: 256, height: 4, depth: 4, datatype: .int16, pixdim: [1, pixdim, pixdim, pixdim])
            let volume = MIQVolume(image: try MIQParser().parseNifti(data))
            return SlicePlane.allCases.map {
                let image = volume.centerSlice(plane: $0, options: options)
                return [image.width, image.height]
            }
        }
        let tiny = try sizes(pixdim: 1e-9), unit = try sizes(pixdim: 1)
        #expect(tiny == unit)
    }

    @Test
    func resampleTargetSizeFallsBackOnNonFiniteExtent() throws {
        let target = try #require(ResampleTargetSize(
            width: 300, height: 20,
            pixelSpacingX: .infinity, pixelSpacingY: 1,
            maxPhysicalExtent: .infinity, maxDimension: 256
        ))
        #expect(target.width == 256 && target.height == 20)
    }
}
