import Foundation
import Testing
@testable import MIQCore

private let testRenderingOptions = RenderingOptions(lowerPercentile: 2.0, upperPercentile: 98.0)

struct MIQCoreTests {
    private static func tempURL(suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-test-\(UUID().uuidString)\(suffix)")
    }

    @Test
    func parsesLittleEndianHeader() throws {
        let data = TestMIQFactory.makeNii(width: 4, height: 3, depth: 2, datatype: .uint8)
        let header = try MIQParser().parseNiftiHeader(from: data)

        #expect(header.width == 4)
        #expect(header.height == 3)
        #expect(header.depth == 2)
        #expect(header.datatype == .uint8)
        #expect(header.voxOffset >= 352)
    }

    @Test
    func rendersThreeCenterSlices() throws {
        let data = TestMIQFactory.makeNii(width: 8, height: 6, depth: 4, datatype: .uint8)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)

        let coronal = volume.centerSlice(plane: .coronal, options: testRenderingOptions)
        let sagittal = volume.centerSlice(plane: .sagittal, options: testRenderingOptions)
        let axial = volume.centerSlice(plane: .axial, options: testRenderingOptions)

        #expect(coronal.width > 0)
        #expect(coronal.height > 0)
        #expect(sagittal.width > 0)
        #expect(sagittal.height > 0)
        #expect(axial.width > 0)
        #expect(axial.height > 0)

        let coronalRatio = Double(coronal.width) / Double(coronal.height)
        let sagittalRatio = Double(sagittal.width) / Double(sagittal.height)
        let axialRatio = Double(axial.width) / Double(axial.height)
        #expect(abs(coronalRatio - 2.0) < 0.05)
        #expect(abs(sagittalRatio - 1.5) < 0.05)
        #expect(abs(axialRatio - (8.0 / 6.0)) < 0.05)
    }

    @Test
    func fixedCenterWindowMatchesSharedCenterSliceRendering() throws {
        let data = TestMIQFactory.makeNii(width: 8, height: 6, depth: 4, datatype: .int16)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let shared = volume.centerSlices(options: testRenderingOptions)
        let window = try #require(volume.fixedCenterWindow(options: testRenderingOptions))

        for plane in SlicePlane.allCases {
            let rendered = volume.centerSlice(plane: plane, options: testRenderingOptions, windowBounds: window)
            switch (shared[plane], rendered) {
            case (.grayscale(let a)?, .grayscale(let b)):
                #expect(a.width == b.width)
                #expect(a.height == b.height)
                #expect(a.pixels == b.pixels)
            case (.rgb(let a)?, .rgb(let b)):
                #expect(a.width == b.width)
                #expect(a.height == b.height)
                #expect(a.pixels == b.pixels)
            default:
                Issue.record("slice rendering with fixed shared window did not match centerSlices output")
            }
        }
    }

    @Test
    func fixedCenterWindowIsNilForColorVolumes() throws {
        let data = TestMIQFactory.makeNii(width: 8, height: 6, depth: 4, datatype: .rgb24)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)

        #expect(volume.fixedCenterWindow(options: testRenderingOptions) == nil)
    }

    @Test
    func sliceCursorRoundTripsThroughNormalizedCoordinates() throws {
        let mif = TestMIQFactory.makeMif(width: 8, height: 6, depth: 4, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)

        let volume = MIQVolume(image: try MIQParser().parse(url: url))
        let options = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .neurological)
        let cursor = MIQVolumeCursor(x: 2, y: 3, z: 1)

        for plane in SlicePlane.allCases {
            let normalized = volume.normalizedPoint(for: plane, cursor: cursor, options: options)
            let sliceIndex = volume.sliceIndex(for: plane, cursor: cursor, options: options)
            let recovered = volume.cursor(for: plane, sliceIndex: sliceIndex, normalizedPoint: normalized, options: options)
            #expect(recovered == cursor)
        }
    }

    @Test
    func extractsMetadataLines() throws {
        let data = TestMIQFactory.makeNii(width: 16, height: 8, depth: 4, datatype: .int16, pixdim: [1, 0.8, 0.8, 1.4])
        let image = try MIQParser().parseNifti(data)
        let lines = MIQMetadata(header: image.header).asDisplayLines()

        #expect(lines.contains(where: { $0.text.contains("Dimensions: 16 x 8 x 4") }))
        #expect(lines.contains(where: { $0.text.contains("Datatype: int16") }))
    }

    @Test
    func metadataIncludesScalingOnlyWhenNonIdentity() {
        let scaledHeader = MIQHeader(
            littleEndian: true,
            dimensions: [16, 8, 4, 1],
            pixdim: [1, 0.8, 0.8, 1.4],
            datatype: .int16,
            voxOffset: 352,
            sclSlope: 0.004,
            sclInter: 1024,
            qformCode: 0,
            sformCode: 0,
            srowX: [],
            srowY: [],
            srowZ: []
        )
        let scaledLines = MIQMetadata(header: scaledHeader).asDisplayLines()

        #expect(scaledLines.contains(where: { $0.field == .scaling && $0.text == "Scaling: x 0.004 + 1024.000" }))

        let identityHeader = MIQHeader(
            littleEndian: true,
            dimensions: [16, 8, 4, 1],
            pixdim: [1, 0.8, 0.8, 1.4],
            datatype: .int16,
            voxOffset: 352,
            sclSlope: 1,
            sclInter: 0,
            qformCode: 0,
            sformCode: 0,
            srowX: [],
            srowY: [],
            srowZ: []
        )
        let unavailableHeader = MIQHeader(
            littleEndian: true,
            dimensions: [16, 8, 4, 1],
            pixdim: [1, 0.8, 0.8, 1.4],
            datatype: .int16,
            voxOffset: 352,
            sclSlope: 0,
            sclInter: 0,
            qformCode: 0,
            sformCode: 0,
            srowX: [],
            srowY: [],
            srowZ: []
        )

        #expect(!MIQMetadata(header: identityHeader).asDisplayLines().contains(where: { $0.field == .scaling }))
        #expect(!MIQMetadata(header: unavailableHeader).asDisplayLines().contains(where: { $0.field == .scaling }))
    }

    @Test
    func parseMetadataOrderAppendsScalingForOlderSettings() {
        let parsed = MIQConfig.parseMetadataOrder("format,dimensions,spacing,orientation,datatype,volumes")

        #expect(parsed.contains(.scaling))
        #expect(parsed.last == .scaling)
    }

    @Test
    func parsesFromFileURLWithOffsetBackedPayload() throws {
        let data = TestMIQFactory.makeNii(width: 5, height: 4, depth: 3, datatype: .uint8)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).nii")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try data.write(to: fileURL)

        let image = try MIQParser().parse(url: fileURL)
        #expect(image.payloadOffset >= 352)
        #expect(image.payloadCount == 5 * 4 * 3)

        let volume = MIQVolume(image: image)
        let center = volume.centerSlice(plane: .axial, options: testRenderingOptions)
        #expect(center.width > 0)
        #expect(center.height > 0)
        let ratio = Double(center.width) / Double(center.height)
        #expect(abs(ratio - 1.25) < 0.05)
    }

    /// Partial decompression must produce a volume-0 view byte-identical to a
    /// full decompression for a 4D NIfTI, while actually truncating the payload
    /// (proving the optimization engaged, not silently doing full work).
    @Test
    func partialDecompressionMatchesFullForFourDNifti() throws {
        let w = 8, h = 6, d = 4, t = 5
        let raw = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16, volumes: t)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let plainURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).nii")
        let gzURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).nii.gz")
        defer {
            try? FileManager.default.removeItem(at: plainURL)
            try? FileManager.default.removeItem(at: gzURL)
        }
        try raw.write(to: plainURL)
        try TestZlib.gzip(raw).write(to: gzURL)

        let full = try MIQParser().parse(url: plainURL)      // whole payload (all 5 volumes)
        let partial = try MIQParser().parse(url: gzURL)       // gz → volume-0-only prefix

        let bpv = MIQDatatype.int16.bytesPerVoxel
        #expect(full.payloadCount == w * h * d * t * bpv)
        #expect(partial.payloadCount == w * h * d * bpv)      // truncated to volume 0
        #expect(partial.payloadCount < full.payloadCount)     // optimization engaged

        let fullVol = MIQVolume(image: full)
        let partialVol = MIQVolume(image: partial)
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    #expect(partialVol.voxel(x: x, y: y, z: z, t: 0) == fullVol.voxel(x: x, y: y, z: z, t: 0))
                }
            }
        }
        for plane in SlicePlane.allCases {
            let a = fullVol.centerSlice(plane: plane, options: testRenderingOptions)
            let b = partialVol.centerSlice(plane: plane, options: testRenderingOptions)
            #expect(a.width == b.width)
            #expect(a.height == b.height)
        }
    }

    /// Bounded-prefix disk read (the network fast path) must yield a volume-0
    /// view byte-identical to a full parse, while reading less than the whole
    /// `.nii.gz` payload. Volume 0 must exceed the 64 KB header probe so the
    /// budget actually engages (small files legitimately decompress in full).
    @Test
    func boundedPrefixReadMatchesFullForFourDNiftiGz() throws {
        let w = 64, h = 64, d = 20, t = 5
        let raw = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16, volumes: t)
        let plainURL = Self.tempURL(suffix: ".nii")
        let gzURL = Self.tempURL(suffix: ".nii.gz")
        let prefixURL = Self.tempURL(suffix: ".nii")
        defer {
            try? FileManager.default.removeItem(at: plainURL)
            try? FileManager.default.removeItem(at: gzURL)
            try? FileManager.default.removeItem(at: prefixURL)
        }
        try raw.write(to: plainURL)
        try TestZlib.gzip(raw).write(to: gzURL)

        let full = try MIQParser().parse(url: plainURL) // all t volumes
        let bpv = MIQDatatype.int16.bytesPerVoxel
        let volumeBytes = w * h * d * bpv

        // Bypass the isLocalVolume gate (a temp file is local) by calling the
        // bounded reader directly — same Data loadAndDecompress would feed the parser.
        let prefix = try #require(try MIQParser().loadBoundedNiftiPrefix(url: gzURL, kind: .niiGz))
        #expect(prefix.count < raw.count)          // read less than the whole payload
        #expect(prefix.count >= volumeBytes)       // but enough for volume 0

        try prefix.write(to: prefixURL)
        let partial = MIQVolume(image: try MIQParser().parse(url: prefixURL))
        let fullVol = MIQVolume(image: full)
        for z in 0..<d {
            for y in 0..<h {
                for x in stride(from: 0, to: w, by: 7) { // sample, not all 320 k voxels
                    #expect(partial.voxel(x: x, y: y, z: z, t: 0) == fullVol.voxel(x: x, y: y, z: z, t: 0))
                }
            }
        }
    }

    /// Bounded-prefix read for an *uncompressed* 4D `.nii`: reads exactly the
    /// volume-0 budget (no mmap fallback over a network volume), truncating the
    /// trailing volumes while keeping volume 0 byte-identical.
    @Test
    func boundedPrefixReadMatchesFullForFourDNiftiPlain() throws {
        let w = 8, h = 6, d = 4, t = 5
        let raw = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16, volumes: t)
        let plainURL = Self.tempURL(suffix: ".nii")
        let prefixURL = Self.tempURL(suffix: ".nii")
        defer {
            try? FileManager.default.removeItem(at: plainURL)
            try? FileManager.default.removeItem(at: prefixURL)
        }
        try raw.write(to: plainURL)

        let prefix = try #require(try MIQParser().loadBoundedNiftiPrefix(url: plainURL, kind: .nii))
        #expect(prefix.count < raw.count) // trailing volumes skipped

        try prefix.write(to: prefixURL)
        let partialImage = try MIQParser().parse(url: prefixURL)
        // Header is untouched (still 5 volumes); only the payload is truncated to
        // volume 0 — reads past it return the zero backstop, exactly like the gz cap.
        #expect(partialImage.payloadCount == w * h * d * MIQDatatype.int16.bytesPerVoxel)
        let partial = MIQVolume(image: partialImage)
        let fullVol = MIQVolume(image: try MIQParser().parse(url: plainURL))
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    #expect(partial.voxel(x: x, y: y, z: z, t: 0) == fullVol.voxel(x: x, y: y, z: z, t: 0))
                }
            }
        }
    }

    /// `containsAllVolumes` distinguishes a volume-0-capped buffer from a full
    /// one — the signal the preview layer uses to decide a 4D buffer needs
    /// expansion (covers the bounded uncompressed `.nii` case the old kind-based
    /// check missed).
    @Test
    func containsAllVolumesReflectsBoundedPrefix() throws {
        let w = 8, h = 6, d = 4, t = 5
        let raw = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16, volumes: t)
        let url = Self.tempURL(suffix: ".nii")
        let prefixURL = Self.tempURL(suffix: ".nii")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: prefixURL)
        }
        try raw.write(to: url)

        let full = MIQVolume(image: try MIQParser().parse(url: url))
        #expect(full.volumes == t)
        #expect(full.containsAllVolumes)

        let prefix = try #require(try MIQParser().loadBoundedNiftiPrefix(url: url, kind: .nii))
        try prefix.write(to: prefixURL)
        let capped = MIQVolume(image: try MIQParser().parse(url: prefixURL))
        #expect(capped.volumes == t)         // header still declares all volumes
        #expect(!capped.containsAllVolumes)   // but the payload only holds volume 0
    }

    /// `VolumeLocation.isLocal` reports a temp file (always on a local volume) as
    /// local, and defaults to local on a failed probe — the conservative fallback
    /// that preserves the mmap fast path / generates thumbnails.
    @Test
    func volumeLocationReportsLocalForLocalFileAndOnFailure() throws {
        let url = Self.tempURL(suffix: ".nii")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        #expect(VolumeLocation.isLocal(url))
        #expect(VolumeLocation.isLocal(URL(fileURLWithPath: "/no/such/path/file.nii")))
    }

    /// The bounded reader declines kinds whose volume 0 isn't a file prefix, so
    /// the caller falls back to the full read (`.mgz` here).
    @Test
    func boundedPrefixReadDeclinesNonNiftiKinds() throws {
        let mgh = TestMIQFactory.makeMgh(width: 5, height: 3, depth: 2, frames: 1, datatype: .int16)
        let mgzURL = Self.tempURL(suffix: ".mgz")
        defer { try? FileManager.default.removeItem(at: mgzURL) }
        try TestZlib.gzip(mgh).write(to: mgzURL)
        #expect(try MIQParser().loadBoundedNiftiPrefix(url: mgzURL, kind: .mgz) == nil)
    }

    // MARK: - 4D navigation

    /// `t` must participate in equality/hash: a timepoint change has to
    /// invalidate a displayed frame. (This is the building block the extension's
    /// `planesNeedingRender` relies on for its `oldCursor.t != newCursor.t`
    /// short-circuit; that lives in the QL target and isn't SPM-testable.)
    @Test
    func volumeCursorIncludesTimepointInEquality() {
        let a = MIQVolumeCursor(x: 2, y: 3, z: 1, t: 0)
        let b = MIQVolumeCursor(x: 2, y: 3, z: 1, t: 4)
        let c = MIQVolumeCursor(x: 2, y: 3, z: 1, t: 4)
        #expect(a != b)
        #expect(b == c)
        #expect(Set([a, b, c]).count == 2)
        #expect(MIQVolumeCursor(x: 0, y: 0, z: 0) == MIQVolumeCursor(x: 0, y: 0, z: 0, t: 0))
    }

    /// 4D voxel addressing: `voxel(...,t:)` — the correctness reference the hot
    /// slice loop must stay bit-identical to — resolves the right per-volume
    /// element, and an out-of-range timepoint returns the zero backstop rather
    /// than reading a neighbouring volume or crashing.
    @Test
    func fourDVoxelAddressingMatchesFillPattern() throws {
        let w = 5, h = 4, d = 3, t = 6
        let raw = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16, volumes: t)
        let url = Self.tempURL(suffix: ".nii")
        defer { try? FileManager.default.removeItem(at: url) }
        try raw.write(to: url)
        let vol = MIQVolume(image: try MIQParser().parse(url: url))

        // makeNii int16 fill: value at global flat index
        // i = x + y*W + z*W*H + tp*W*H*D is i % 1024.
        for tp in [0, 1, t - 1] {
            for z in 0..<d {
                for y in 0..<h {
                    for x in 0..<w {
                        let i = x + y * w + z * w * h + tp * w * h * d
                        #expect(vol.voxel(x: x, y: y, z: z, t: tp) == Float(i % 1024))
                    }
                }
            }
        }
        #expect(vol.voxel(x: 1, y: 1, z: 1, t: t) == 0)
        #expect(vol.voxel(x: 0, y: 0, z: 0, t: 999) == 0)
    }

    /// The render path honours `volumeIndex`: volume 0 of a 4D file is
    /// byte-identical to the same 3D file (no t==0 regression), and an
    /// out-of-range volume renders a uniform zero slice instead of garbage.
    /// (Per-volume *data* correctness is covered at the voxel level by
    /// `fourDVoxelAddressingMatchesFillPattern` and the gz test below;
    /// `makeNii`'s linear ramp differs only by an additive constant between
    /// volumes, which percentile windowing intentionally normalises away.)
    @Test
    func centerSliceSelectsRequestedVolume() throws {
        let w = 8, h = 6, d = 4, t = 5
        let raw4D = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16, volumes: t)
        let raw3D = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16)
        let url4D = Self.tempURL(suffix: ".nii")
        let url3D = Self.tempURL(suffix: ".nii")
        defer {
            try? FileManager.default.removeItem(at: url4D)
            try? FileManager.default.removeItem(at: url3D)
        }
        try raw4D.write(to: url4D)
        try raw3D.write(to: url3D)
        let vol4D = MIQVolume(image: try MIQParser().parse(url: url4D))
        let vol3D = MIQVolume(image: try MIQParser().parse(url: url3D))

        guard case .grayscale(let v0) = vol4D.centerSlice(plane: .axial, volumeIndex: 0, options: testRenderingOptions),
              case .grayscale(let only) = vol3D.centerSlice(plane: .axial, options: testRenderingOptions),
              case .grayscale(let oob) = vol4D.centerSlice(plane: .axial, volumeIndex: t, options: testRenderingOptions) else {
            Issue.record("expected grayscale slices")
            return
        }
        // Volume 0 of the 4D file == the equivalent 3D file (identical payload
        // bytes; the 4D path adds no t==0 regression).
        #expect(v0.width == only.width && v0.height == only.height)
        #expect(v0.pixels == only.pixels)
        // Out-of-range volume → zero backstop, never garbage.
        #expect(Set(oob.pixels).count <= 1)
    }

    /// Phase 2: the default gz parse caps at volume 0 (timepoints > 0 backstop
    /// to zero), while `fullyDecompress: true` recovers every volume identical
    /// to the uncompressed reference. Volume 0 is invariant across all paths.
    @Test
    func fullyDecompressRecoversAllVolumesForFourDGz() throws {
        let w = 8, h = 6, d = 4, t = 5
        let raw = TestMIQFactory.makeNii(width: w, height: h, depth: d, datatype: .int16, volumes: t)
        let plainURL = Self.tempURL(suffix: ".nii")
        let gzURL = Self.tempURL(suffix: ".nii.gz")
        defer {
            try? FileManager.default.removeItem(at: plainURL)
            try? FileManager.default.removeItem(at: gzURL)
        }
        try raw.write(to: plainURL)
        try TestZlib.gzip(raw).write(to: gzURL)

        let bpv = MIQDatatype.int16.bytesPerVoxel
        let plainImg = try MIQParser().parse(url: plainURL)
        let cappedImg = try MIQParser().parse(url: gzURL)
        let fullImg = try MIQParser().parse(url: gzURL, fullyDecompress: true)

        #expect(cappedImg.payloadCount == w * h * d * bpv)          // volume 0 only
        #expect(fullImg.payloadCount == w * h * d * t * bpv)        // every volume
        #expect(fullImg.payloadCount == plainImg.payloadCount)

        let plain = MIQVolume(image: plainImg)
        let capped = MIQVolume(image: cappedImg)
        let full = MIQVolume(image: fullImg)
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    #expect(capped.voxel(x: x, y: y, z: z, t: 0) == plain.voxel(x: x, y: y, z: z, t: 0))
                    #expect(full.voxel(x: x, y: y, z: z, t: 0) == plain.voxel(x: x, y: y, z: z, t: 0))
                    #expect(capped.voxel(x: x, y: y, z: z, t: 1) == 0)
                    #expect(full.voxel(x: x, y: y, z: z, t: 1) == plain.voxel(x: x, y: y, z: z, t: 1))
                }
            }
        }
    }

    // MARK: - ScrollStepResolver

    private func scrollInput(
        option: Bool = false,
        began: Bool = false,
        legacy: Bool = false,
        dx: Double = 0,
        dy: Double = 0,
        precise: Bool = false
    ) -> ScrollStepInput {
        ScrollStepInput(
            optionHeld: option,
            phaseBegan: began,
            isLegacyWheel: legacy,
            deltaX: dx,
            deltaY: dy,
            hasPreciseDeltas: precise
        )
    }

    /// Legacy wheel uses the live modifier; volume steps are the inverse of the
    /// slice step for the same physical scroll direction.
    @Test
    func scrollResolverLegacyWheelRoutesByModifierAndInvertsVolume() {
        var slice = ScrollStepResolver()
        var volume = ScrollStepResolver()
        let s = slice.resolve(scrollInput(legacy: true, dy: 1), onBegan: {})
        let v = volume.resolve(scrollInput(option: true, legacy: true, dy: 1), onBegan: {})
        #expect(s?.axis == .slice)
        #expect(v?.axis == .volume)
        #expect(s?.step != nil && v?.step != nil)
        #expect(s!.step == -v!.step)   // 4D inverted vs slice
    }

    /// Precise (trackpad) deltas accumulate; no step until the threshold is
    /// crossed, then the remainder carries into the next event.
    @Test
    func scrollResolverPreciseDeltasAccumulateToThreshold() {
        var r = ScrollStepResolver()
        #expect(r.resolve(scrollInput(began: true, dy: 8, precise: true), onBegan: {}) == nil)
        let stepped = r.resolve(scrollInput(dy: 8, precise: true), onBegan: {})
        #expect(stepped?.axis == .slice)            // 16 ≥ 14 → one step
        #expect(stepped?.step == -1)                // dy > 0 → slice -1
        // 16 − 14 = 2 carried; a small follow-up still can't reach 14 alone.
        #expect(r.resolve(scrollInput(dy: 8, precise: true), onBegan: {}) == nil)  // 2+8=10
        #expect(r.resolve(scrollInput(dy: 8, precise: true), onBegan: {})?.step == -1) // 18 ≥ 14
    }

    /// The modifier latched at `.began` holds through subsequent (momentum)
    /// events while Option stays down.
    @Test
    func scrollResolverLatchesModifierThroughMomentum() {
        var r = ScrollStepResolver()
        let a = r.resolve(scrollInput(option: true, began: true, dy: 20, precise: true), onBegan: {})
        let b = r.resolve(scrollInput(option: true, dy: 20, precise: true), onBegan: {})
        #expect(a?.axis == .volume)
        #expect(b?.axis == .volume)
    }

    /// Releasing Option mid volume-gesture swallows the rest of the gesture and
    /// its inertia (does not leak into slice scrolling), until the next `.began`.
    @Test
    func scrollResolverReleasingOptionCancelsRemainder() {
        var r = ScrollStepResolver()
        #expect(r.resolve(scrollInput(option: true, began: true, dy: 20, precise: true), onBegan: {})?.axis == .volume)
        #expect(r.resolve(scrollInput(option: false, dy: 20, precise: true), onBegan: {}) == nil)  // released → cancel
        #expect(r.resolve(scrollInput(option: true, dy: 20, precise: true), onBegan: {}) == nil)   // stays swallowed
        // A fresh gesture recovers.
        #expect(r.resolve(scrollInput(began: true, dy: 20, precise: true), onBegan: {})?.axis == .slice)
    }

    /// A gesture latched to slice ignores Option pressed mid-gesture (no axis
    /// flip from inertia/modifier changes).
    @Test
    func scrollResolverSliceGestureIgnoresLaterOption() {
        var r = ScrollStepResolver()
        #expect(r.resolve(scrollInput(began: true, dy: 20, precise: true), onBegan: {})?.axis == .slice)
        #expect(r.resolve(scrollInput(option: true, dy: 20, precise: true), onBegan: {})?.axis == .slice)
    }

    /// Zero delta yields no step, and `onBegan` fires exactly once per gesture.
    @Test
    func scrollResolverZeroDeltaAndOnBeganOnce() {
        var r = ScrollStepResolver()
        var beganCount = 0
        #expect(r.resolve(scrollInput(began: true, dy: 0), onBegan: { beganCount += 1 }) == nil)
        _ = r.resolve(scrollInput(dy: 8, precise: true), onBegan: { beganCount += 1 })
        _ = r.resolve(scrollInput(dy: 8, precise: true), onBegan: { beganCount += 1 })
        #expect(beganCount == 1)
    }

    /// 3D NIfTI: the budget equals the full payload, so the streaming inflater
    /// must yield exactly the same bytes as the single-shot path (no regression).
    @Test
    func partialDecompressionFullStreamMatchesForThreeDNifti() throws {
        let raw = TestMIQFactory.makeNii(width: 7, height: 5, depth: 3, datatype: .int16)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let plainURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).nii")
        let gzURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).nii.gz")
        defer {
            try? FileManager.default.removeItem(at: plainURL)
            try? FileManager.default.removeItem(at: gzURL)
        }
        try raw.write(to: plainURL)
        try TestZlib.gzip(raw).write(to: gzURL)

        let full = try MIQParser().parse(url: plainURL)
        let gz = try MIQParser().parse(url: gzURL)

        #expect(gz.payloadCount == full.payloadCount)
        let fullVol = MIQVolume(image: full)
        let gzVol = MIQVolume(image: gz)
        for z in 0..<3 {
            for y in 0..<5 {
                for x in 0..<7 {
                    #expect(gzVol.voxel(x: x, y: y, z: z) == fullVol.voxel(x: x, y: y, z: z))
                }
            }
        }
    }

    @Test
    func parsesMghAndRendersSlices() throws {
        let data = TestMIQFactory.makeMgh(width: 6, height: 4, depth: 3, frames: 1, datatype: .uint8)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).mgh")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try data.write(to: fileURL)
        let image = try MIQParser().parse(url: fileURL)

        #expect(image.header.width == 6)
        #expect(image.header.height == 4)
        #expect(image.header.depth == 3)
        #expect(image.header.voxOffset == 284)
        #expect(image.header.datatype == .uint8)

        let volume = MIQVolume(image: image)
        let axial = volume.centerSlice(plane: .axial, options: testRenderingOptions)
        #expect(axial.width > 0)
        #expect(axial.height > 0)
        let ratio = Double(axial.width) / Double(axial.height)
        #expect(abs(ratio - 1.5) < 0.05)
    }

    @Test
    func parsesMgzFromFileURL() throws {
        let mghData = TestMIQFactory.makeMgh(width: 5, height: 3, depth: 2, frames: 1, datatype: .int16)
        let mgzData = try TestZlib.gzip(mghData)

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).mgz")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try mgzData.write(to: fileURL)
        let image = try MIQParser().parse(url: fileURL)

        #expect(image.header.width == 5)
        #expect(image.header.height == 3)
        #expect(image.header.depth == 2)
        #expect(image.header.datatype == .int16)
        #expect(image.payloadOffset == 284)
    }

    @Test
    func parsesMifFromFileURL() throws {
        let mifData = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).mif")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try mifData.write(to: fileURL)
        let image = try MIQParser().parse(url: fileURL)
        let volume = MIQVolume(image: image)

        #expect(image.header.width == 4)
        #expect(image.header.height == 3)
        #expect(image.header.depth == 2)
        #expect(image.header.datatype == .uint8)
        #expect(image.payloadOffset >= 0)
        #expect(image.payloadCount >= 4 * 3 * 2)
        #expect(Int(volume.voxel(x: 3, y: 2, z: 1)) == 123)
    }

    @Test
    func parsesMifGzFromFileURL() throws {
        let mifData = TestMIQFactory.makeMif(width: 5, height: 4, depth: 2, datatype: .int16, layout: [0, 1, 2])
        let mifGzData = try TestZlib.gzip(mifData)
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).mif.gz")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try mifGzData.write(to: fileURL)
        let image = try MIQParser().parse(url: fileURL)

        #expect(image.header.width == 5)
        #expect(image.header.height == 4)
        #expect(image.header.depth == 2)
        #expect(image.header.datatype == .int16)
        #expect(image.payloadOffset >= 0)
        #expect(image.payloadCount >= 5 * 4 * 2 * 2)
    }

    @Test
    func parsesNifti2Header() throws {
        let data = TestMIQFactory.makeNii2(width: 4, height: 3, depth: 2, datatype: .uint8)
        let header = try MIQParser().parseNiftiHeader(from: data)

        #expect(header.width == 4)
        #expect(header.height == 3)
        #expect(header.depth == 2)
        #expect(header.datatype == .uint8)
        #expect(header.voxOffset >= 544)
    }

    @Test
    func parsesNifti2AndRendersSlices() throws {
        let data = TestMIQFactory.makeNii2(width: 8, height: 6, depth: 4, datatype: .int16,
                                           pixdim: [1, 0.8, 0.8, 1.4])
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)

        let axial = volume.centerSlice(plane: .axial, options: testRenderingOptions)
        let coronal = volume.centerSlice(plane: .coronal, options: testRenderingOptions)
        let sagittal = volume.centerSlice(plane: .sagittal, options: testRenderingOptions)

        #expect(axial.width > 0 && axial.height > 0)
        #expect(coronal.width > 0 && coronal.height > 0)
        #expect(sagittal.width > 0 && sagittal.height > 0)
    }

    @Test
    func parsesNonCanonicalMifWithoutScramble() throws {
        let mifData = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [1, 0, 2])
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).mif")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try mifData.write(to: fileURL)
        let image = try MIQParser().parse(url: fileURL)
        let volume = MIQVolume(image: image)

        // Storage-axis display: spatial axes are permuted by storage rank.
        // layout [1,0,2]: axis 1 (y, dim=3) is fastest → new width=3,
        //                 axis 0 (x, dim=4) is next   → new height=4,
        //                 axis 2 (z, dim=2) is slowest → new depth=2.
        #expect(image.header.width == 3)
        #expect(image.header.height == 4)
        #expect(image.header.depth == 2)
        #expect(Int(volume.voxel(x: 0, y: 0, z: 0)) == 0)
        // new(x=2,y=3,z=1) → old(y=2,x=3,z=1) → value=3+20+100=123
        #expect(Int(volume.voxel(x: 2, y: 3, z: 1)) == 123)
        // new(x=2,y=1,z=0) → old(y=2,x=1,z=0) → value=1+20+0=21
        #expect(Int(volume.voxel(x: 2, y: 1, z: 0)) == 21)
    }

    @Test
    func parsesReversedAxisMifWithExplicitNegative() throws {
        // Explicit negative stride in symbolic layout.
        // storage axis 0 (x) is reversed, storage axis 1 (y) is fastest.
        // The factory writes via signed strides + base (so the on-disk payload is a
        // valid reversed-axis MIF); the parser reads with absolute strides + base 0
        // and uses the layout sign only to derive orientation labels. The asserts
        // below therefore see the data "as stored", not flipped back.
        let width = 4
        let height = 3
        let depth = 2
        let mifData = TestMIQFactory.makeMif(width: width, height: height, depth: depth, datatype: .uint8, layout: [-1, 0, 2])
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tmpDir.appendingPathComponent("miq-test-\(UUID().uuidString).mif")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try mifData.write(to: fileURL)
        let image = try MIQParser().parse(url: fileURL)
        let volume = MIQVolume(image: image)

        // After permutation by abs(layout): spatialAxes=[1,0,2], so display width = storage height = 3,
        // display height = storage width = 4, display depth = storage depth = 2.
        #expect(image.header.width == height)
        #expect(image.header.height == width)
        #expect(image.header.depth == depth)

        // Storage-order rendering mirrors reversed x traversal.
        #expect(Int(volume.voxel(x: 0, y: 0, z: 0)) == 3)
        #expect(Int(volume.voxel(x: 2, y: 0, z: 0)) == 23)
        #expect(Int(volume.voxel(x: 0, y: 3, z: 1)) == 100)
    }

    @Test
    func parsesNiftiRgb24AndRendersColorSlices() throws {
        let data = TestMIQFactory.makeNii(width: 8, height: 6, depth: 4, datatype: .rgb24)
        let image = try MIQParser().parseNifti(data)

        #expect(image.header.datatype == .rgb24)
        #expect(image.header.width == 8)
        #expect(image.header.height == 6)
        #expect(image.header.depth == 4)
        #expect(image.payloadCount == 8 * 6 * 4 * 3)

        let volume = MIQVolume(image: image)
        let axial = volume.centerSlice(plane: .axial, options: testRenderingOptions)
        let coronal = volume.centerSlice(plane: .coronal, options: testRenderingOptions)
        let sagittal = volume.centerSlice(plane: .sagittal, options: testRenderingOptions)

        if case .rgb(let img) = axial {
            #expect(img.width > 0 && img.height > 0)
            #expect(img.pixels.count == img.width * img.height * 3)
        } else {
            Issue.record("expected rgb slice for rgb24 datatype")
        }
        #expect(coronal.width > 0 && coronal.height > 0)
        #expect(sagittal.width > 0 && sagittal.height > 0)

        let lines = MIQMetadata(header: image.header).asDisplayLines()
        #expect(lines.contains(where: { $0.text.contains("Datatype: rgb24") }))
    }

    @Test
    func parsesNiftiRgba32AndRendersColorSlices() throws {
        let data = TestMIQFactory.makeNii(width: 6, height: 4, depth: 3, datatype: .rgba32)
        let image = try MIQParser().parseNifti(data)

        #expect(image.header.datatype == .rgba32)
        #expect(image.payloadCount == 6 * 4 * 3 * 4)

        let volume = MIQVolume(image: image)
        let axial = volume.centerSlice(plane: .axial, options: testRenderingOptions)

        if case .rgb(let img) = axial {
            #expect(img.width > 0 && img.height > 0)
            #expect(img.pixels.count == img.width * img.height * 3)
        } else {
            Issue.record("expected rgb slice for rgba32 datatype")
        }

        let lines = MIQMetadata(header: image.header).asDisplayLines()
        #expect(lines.contains(where: { $0.text.contains("Datatype: rgba32") }))
    }

    @Test
    func parsesRawNrrdWithLpsSpaceConvertedToRas() throws {
        // LPS direction vectors (1,0,0)(0,1,0)(0,0,1) must be sign-flipped
        // to RAS in the sform: storage x → -R (L), storage y → -A (P), storage z → S.
        let data = TestMIQFactory.makeNrrd(
            width: 5,
            height: 4,
            depth: 3,
            datatype: .uint8,
            space: "left-posterior-superior"
        )
        let image = try MIQParser().parseNrrd(data)

        #expect(image.header.width == 5)
        #expect(image.header.height == 4)
        #expect(image.header.depth == 3)
        #expect(image.header.datatype == .uint8)
        #expect(image.header.sformCode == 1)

        // sform column 0 (storage x direction in RAS): (-1, 0, 0) → L
        // sform column 1 (storage y direction in RAS): (0, -1, 0) → P
        // sform column 2 (storage z direction in RAS): (0, 0, 1) → S
        #expect(image.header.srowX[0] == -1)
        #expect(image.header.srowY[0] == 0)
        #expect(image.header.srowZ[0] == 0)
        #expect(image.header.srowX[1] == 0)
        #expect(image.header.srowY[1] == -1)
        #expect(image.header.srowZ[1] == 0)
        #expect(image.header.srowX[2] == 0)
        #expect(image.header.srowY[2] == 0)
        #expect(image.header.srowZ[2] == 1)

        let volume = MIQVolume(image: image)
        let axial = volume.centerSlice(plane: .axial, options: testRenderingOptions)
        let coronal = volume.centerSlice(plane: .coronal, options: testRenderingOptions)
        let sagittal = volume.centerSlice(plane: .sagittal, options: testRenderingOptions)
        #expect(axial.width > 0 && axial.height > 0)
        #expect(coronal.width > 0 && coronal.height > 0)
        #expect(sagittal.width > 0 && sagittal.height > 0)
    }

    @Test
    func storageAxisOrientationsForCanonicalRasMif() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let axes = resolver.storageAxisOrientations()
        #expect(axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test
    func storageAxisOrientationsForLasMif() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let axes = resolver.storageAxisOrientations()
        #expect(axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: false),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test
    func storageAxisOrientationsForPermutedMif() throws {
        // layout [1, 0, 2] makes storage axis 0 anatomically A-P, axis 1 R-L.
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [1, 0, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let axes = resolver.storageAxisOrientations()
        #expect(axes == [
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test
    func storageAxisOrientationsNilWhenNoUsableAffine() throws {
        // Both sform_code and qform_code are zero → orientation frame is nil.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 6, height: 4, depth: 3, datatype: .uint8,
            sformCode: 0,
            srowX: [0, 0, 0, 0], srowY: [0, 0, 0, 0], srowZ: [0, 0, 0, 0],
            qformCode: 0,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 0
        )
        let image = try MIQParser().parseNifti(data)

        let resolver = OrientationResolver(image: image)
        #expect(resolver.storageAxisOrientations() == nil)
    }

    @Test
    func planForStoredModeMatchesLegacyMapping() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let coronal = resolver.plan(for: .coronal, mode: .stored)
        let sagittal = resolver.plan(for: .sagittal, mode: .stored)
        let axial = resolver.plan(for: .axial, mode: .stored)

        // Stored plan must reproduce the original SliceConfig hardcoding exactly.
        #expect((coronal.sliceAxis, coronal.hAxis, coronal.vAxis) == (1, 0, 2))
        #expect(coronal.hReversed == false && coronal.vReversed == true)
        #expect((sagittal.sliceAxis, sagittal.hAxis, sagittal.vAxis) == (0, 1, 2))
        #expect(sagittal.hReversed == false && sagittal.vReversed == true)
        #expect((axial.sliceAxis, axial.hAxis, axial.vAxis) == (2, 0, 1))
        #expect(axial.hReversed == false && axial.vReversed == true)
    }

    @Test
    func planForNeurologicalModeOnCanonicalRasIsIdentity() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .neurological)
        #expect((plan.sliceAxis, plan.hAxis, plan.vAxis) == (1, 0, 2))
        #expect(plan.hReversed == false && plan.vReversed == true)
        #expect(plan.labels.leading == "L" && plan.labels.trailing == "R")
        #expect(plan.labels.top == "S" && plan.labels.bottom == "I")
    }

    @Test
    func planForNeurologicalModeOnLasStorageFlipsHorizontal() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .neurological)
        #expect(plan.hReversed == true)
        #expect(plan.vReversed == true)
        // Labels stay fixed in neurological view regardless of storage orientation.
        #expect(plan.labels.leading == "L" && plan.labels.trailing == "R")
    }

    @Test
    func planForRadiologicalModeOnCanonicalRasFlipsHorizontal() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .radiological)
        #expect(plan.hReversed == true)
        #expect(plan.labels.leading == "R" && plan.labels.trailing == "L")
        #expect(plan.labels.top == "S" && plan.labels.bottom == "I")

        // Sagittal labels are the same in neurological and radiological modes
        // (anterior on viewer's left in both conventions).
        let sag = resolver.plan(for: .sagittal, mode: .radiological)
        #expect(sag.labels.leading == "A" && sag.labels.trailing == "P")
        #expect(sag.labels.top == "S" && sag.labels.bottom == "I")
    }

    @Test
    func planForNeurologicalModeRoutesPermutedStorageToCorrectAnatomicalAxis() throws {
        // layout [1, 0, 2] → storage axis 0 anatomically = A-P, axis 1 = R-L.
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [1, 0, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .neurological)
        // The neurological coronal slice must slice along the A-P axis (storage 0 here)
        // and walk the R-L axis (storage 1) horizontally — different from the stored
        // mapping which would slice along storage axis 1.
        #expect(plan.sliceAxis == 0)
        #expect(plan.hAxis == 1)
        #expect(plan.vAxis == 2)
        #expect(plan.hReversed == false)
        #expect(plan.vReversed == true)
    }

    @Test
    func reorientFallsBackToStoredWhenAffineUnknown() throws {
        // Both codes zero → no orientation frame → reoriented modes must collapse to .stored.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 6, height: 4, depth: 3, datatype: .uint8,
            sformCode: 0,
            srowX: [0, 0, 0, 0], srowY: [0, 0, 0, 0], srowZ: [0, 0, 0, 0],
            qformCode: 0,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 0
        )
        let image = try MIQParser().parseNifti(data)

        let resolver = OrientationResolver(image: image)
        let stored = resolver.plan(for: .coronal, mode: .stored)
        let neuro = resolver.plan(for: .coronal, mode: .neurological)
        let radio = resolver.plan(for: .coronal, mode: .radiological)

        #expect(stored.sliceAxis == neuro.sliceAxis && stored.hAxis == neuro.hAxis && stored.vAxis == neuro.vAxis)
        #expect(stored.hReversed == neuro.hReversed && stored.vReversed == neuro.vReversed)
        #expect(stored.sliceAxis == radio.sliceAxis && stored.hAxis == radio.hAxis && stored.vAxis == radio.vAxis)
        #expect(stored.hReversed == radio.hReversed && stored.vReversed == radio.vReversed)
        // Labels should be unknown ("?") since the frame is nil.
        #expect(stored.labels.isUnknown)
        #expect(stored.labels.leading == "?" && stored.labels.trailing == "?")
    }

    @Test
    func volumeDisplayOrientationLabelsRespectMode() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let volume = MIQVolume(image: try MIQParser().parse(url: url))

        let neuroOpt = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .neurological)
        let radioOpt = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .radiological)

        #expect(volume.displayOrientation(for: .coronal, options: neuroOpt).trailing == "R")
        #expect(volume.displayOrientation(for: .coronal, options: radioOpt).trailing == "L")
        #expect(volume.displayOrientation(for: .axial, options: neuroOpt).top == "A")
        #expect(volume.displayOrientation(for: .axial, options: radioOpt).top == "A")
        // Sagittal: anterior on viewer's left in both conventions.
        #expect(volume.displayOrientation(for: .sagittal, options: neuroOpt).leading == "A")
        #expect(volume.displayOrientation(for: .sagittal, options: radioOpt).leading == "A")
    }

    @Test
    func neurologicalModeOnLasStorageHorizontallyMirrorsStoredPixels() throws {
        // Use a volume with enough x-resolution that mirrored columns map to distinct
        // gray levels after percentile normalization.
        let width = 8, height = 4, depth = 4
        let mif = TestMIQFactory.makeMif(width: width, height: height, depth: depth, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let volume = MIQVolume(image: try MIQParser().parse(url: url))

        let stored = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .stored)
        let neuro = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .neurological)
        let storedSlice = volume.centerSlice(plane: .coronal, options: stored)
        let neuroSlice = volume.centerSlice(plane: .coronal, options: neuro)

        guard case .grayscale(let s) = storedSlice, case .grayscale(let r) = neuroSlice else {
            Issue.record("expected grayscale slices")
            return
        }
        #expect(s.width == r.width && s.height == r.height)

        // Every row of the neurological slice is the row-wise horizontal mirror of the stored slice.
        for row in 0..<s.height {
            for col in 0..<s.width {
                let mirror = s.width - 1 - col
                #expect(s.pixels[row * s.width + col] == r.pixels[row * r.width + mirror])
            }
        }
    }

    @Test
    func radiologicalModeOnLasStoragePreservesPixels() throws {
        // LAS-stored data viewed in .radiological mode = no transformation (same plan as .stored).
        let width = 8, height = 4, depth = 4
        let mif = TestMIQFactory.makeMif(width: width, height: height, depth: depth, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let volume = MIQVolume(image: try MIQParser().parse(url: url))

        let stored = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .stored)
        let radio = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .radiological)
        let storedSlice = volume.centerSlice(plane: .coronal, options: stored)
        let radioSlice = volume.centerSlice(plane: .coronal, options: radio)

        guard case .grayscale(let s) = storedSlice, case .grayscale(let l) = radioSlice else {
            Issue.record("expected grayscale slices")
            return
        }
        #expect(s.pixels == l.pixels)
    }

    @Test
    func renderingOptionsHashableIncludesOrientation() {
        let a = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .stored)
        let b = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .neurological)
        let c = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .stored)
        #expect(a != b)
        #expect(a == c)
        #expect(a.hashValue == c.hashValue)
    }

    @Test
    func preservesSignedZeroInMifLayout() throws {
        let width = 4
        let height = 3
        let depth = 2

        let ras = TestMIQFactory.makeMif(
            width: width,
            height: height,
            depth: depth,
            datatype: .uint8,
            layout: [0, 1, 2]
        )
        let lasSignedZero = TestMIQFactory.makeMif(
            width: width,
            height: height,
            depth: depth,
            datatype: .uint8,
            layoutTokens: ["-0", "+1", "+2"]
        )

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let rasURL = tmpDir.appendingPathComponent("miq-test-ras-\(UUID().uuidString).mif")
        let lasURL = tmpDir.appendingPathComponent("miq-test-las-\(UUID().uuidString).mif")
        defer {
            try? FileManager.default.removeItem(at: rasURL)
            try? FileManager.default.removeItem(at: lasURL)
        }

        try ras.write(to: rasURL)
        try lasSignedZero.write(to: lasURL)

        let parser = MIQParser()
        let rasImage = try parser.parse(url: rasURL)
        let lasImage = try parser.parse(url: lasURL)
        let rasVolume = MIQVolume(image: rasImage)
        let lasVolume = MIQVolume(image: lasImage)

        #expect(rasVolume.storageOrientationLabel() == "RAS")
        #expect(lasVolume.storageOrientationLabel() == "LAS")

        // Same coordinate should read different voxels when x traversal is reversed.
        #expect(Int(rasVolume.voxel(x: 0, y: 0, z: 0)) == 0)
        #expect(Int(lasVolume.voxel(x: 0, y: 0, z: 0)) == 3)

        // Opposite edge should also be mirrored.
        #expect(Int(rasVolume.voxel(x: 3, y: 0, z: 0)) == 3)
        #expect(Int(lasVolume.voxel(x: 3, y: 0, z: 0)) == 0)
    }

    // MARK: - OrientationFrame (parser-populated header field)

    @Test
    func niftiOrientationFrameFromSform() throws {
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 1,
            srowX: [1, 0, 0, 0],
            srowY: [0, 1, 0, 0],
            srowZ: [0, 0, 1, 0],
            qformCode: 0,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let header = try MIQParser().parseNiftiHeader(from: data)

        #expect(header.orientationFrame?.source == .sform)
        #expect(header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test
    func niftiOrientationFrameFromQformWhenSformAbsent() throws {
        // sform_code=0, qform_code=1, identity quaternion (b=c=d=0, qfac=+1) → RAS.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 0,
            srowX: [0, 0, 0, 0],
            srowY: [0, 0, 0, 0],
            srowZ: [0, 0, 0, 0],
            qformCode: 1,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let header = try MIQParser().parseNiftiHeader(from: data)

        #expect(header.orientationFrame?.source == .qform)
        #expect(header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test
    func niftiSformWinsOverQformWhenBothPresent() throws {
        // sform encodes a permuted/flipped orientation; qform claims plain RAS.
        // Spec: sform is preferred when both are non-zero.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 1,
            srowX: [0, -1, 0, 0],
            srowY: [0, 0, 1, 0],
            srowZ: [-1, 0, 0, 0],
            qformCode: 1,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let header = try MIQParser().parseNiftiHeader(from: data)

        let frame = try #require(header.orientationFrame)
        #expect(frame.source == .sform)
        // Columns: (R=0,A=0,S=-1) → I, (R=-1,A=0,S=0) → L, (R=0,A=1,S=0) → A
        #expect(frame.axes == [
            StorageAxisOrientation(axis: .superiorInferior, positive: false),
            StorageAxisOrientation(axis: .rightLeft, positive: false),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true)
        ])
    }

    @Test
    func niftiFallsBackToQformWhenSformIsDegenerate() throws {
        // sform_code>0 but rows all zero → degenerate; qform_code>0 must be used.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 1,
            srowX: [0, 0, 0, 0],
            srowY: [0, 0, 0, 0],
            srowZ: [0, 0, 0, 0],
            qformCode: 1,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let header = try MIQParser().parseNiftiHeader(from: data)
        #expect(header.orientationFrame?.source == .qform)
    }

    @Test
    func niftiOrientationFrameNilWhenBothAbsent() throws {
        // Zero codes → no frame derivable. With b=c=d=0 and qfac=0, even fromQuaternion
        // returns nil; both gates fail.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 0,
            srowX: [0, 0, 0, 0],
            srowY: [0, 0, 0, 0],
            srowZ: [0, 0, 0, 0],
            qformCode: 0,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 0
        )
        let header = try MIQParser().parseNiftiHeader(from: data)
        #expect(header.orientationFrame == nil)
    }

    @Test
    func niftiQformQfacReflectsKAxis() throws {
        // Identity quaternion with qfac=-1 flips the k-axis (S→I) per NIfTI-1 spec.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 0,
            srowX: [0, 0, 0, 0],
            srowY: [0, 0, 0, 0],
            srowZ: [0, 0, 0, 0],
            qformCode: 1,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: -1
        )
        let header = try MIQParser().parseNiftiHeader(from: data)
        #expect(header.orientationFrame?.axes[2] == StorageAxisOrientation(axis: .superiorInferior, positive: false))
    }

    @Test
    func mghOrientationFrameFromGoodRas() throws {
        // RAS-aligned direction cosines: axis 0 → R, axis 1 → A, axis 2 → S.
        let data = TestMIQFactory.makeMghWithDirectionCosines(
            width: 4, height: 3, depth: 2, frames: 1, datatype: .uint8,
            xr: 1, xa: 0, xs: 0,
            yr: 0, ya: 1, ys: 0,
            zr: 0, za: 0, zs: 1
        )
        let header = try MIQParser().parseMghHeader(from: data)

        #expect(header.orientationFrame?.source == .mghDirectionCosines)
        #expect(header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test
    func mghOrientationFrameNilWhenGoodRasZero() throws {
        // Existing factory writes goodRAS=0; sform_code=0 path → no frame derivable.
        let data = TestMIQFactory.makeMgh(width: 4, height: 3, depth: 2, frames: 1, datatype: .uint8)
        let header = try MIQParser().parseMghHeader(from: data)
        #expect(header.orientationFrame == nil)
    }

    @Test
    func mifOrientationFrameFromCanonicalRasLayout() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        #expect(image.header.orientationFrame?.source == .mifLayout)
        #expect(image.header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test
    func mifOrientationFrameForLasLayout() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        #expect(image.header.orientationFrame?.source == .mifLayout)
        #expect(image.header.orientationFrame?.axes[0] == StorageAxisOrientation(axis: .rightLeft, positive: false))
    }

    @Test
    func resolverEmitsRealLabelsForNiftiWithSform() throws {
        // NIfTI with explicit RAS sform — resolver should now produce R/A/S labels
        // (previously these would have come from an identity fallback only by coincidence).
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 1,
            srowX: [1, 0, 0, 0],
            srowY: [0, 1, 0, 0],
            srowZ: [0, 0, 1, 0],
            qformCode: 0,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let image = try MIQParser().parseNifti(data)
        let resolver = OrientationResolver(image: image)
        let coronal = resolver.displayOrientation(for: .coronal)
        #expect(coronal.isUnknown == false)
        #expect(coronal.trailing == "R" && coronal.leading == "L")
        #expect(coronal.top == "S" && coronal.bottom == "I")
    }

    @Test
    func resolverEmitsUnknownLabelsWhenFrameAbsent() throws {
        // Zero codes → no frame → all four labels become "?" and isUnknown is set.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 0,
            srowX: [0, 0, 0, 0], srowY: [0, 0, 0, 0], srowZ: [0, 0, 0, 0],
            qformCode: 0,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 0
        )
        let image = try MIQParser().parseNifti(data)
        let resolver = OrientationResolver(image: image)
        let labels = resolver.displayOrientation(for: .coronal)
        #expect(labels.isUnknown)
        #expect(labels.leading == "?" && labels.trailing == "?")
        #expect(labels.top == "?" && labels.bottom == "?")
    }

    @Test
    func resolverEmitsRealLabelsForNiftiWithQformOnly() throws {
        // sform_code=0, qform_code=1 — previously this rendered identity-derived labels
        // (the regression the refactor closes). Resolver must now use the qform frame.
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 4, height: 3, depth: 2, datatype: .uint8,
            sformCode: 0,
            srowX: [0, 0, 0, 0], srowY: [0, 0, 0, 0], srowZ: [0, 0, 0, 0],
            qformCode: 1,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let image = try MIQParser().parseNifti(data)
        let resolver = OrientationResolver(image: image)
        let coronal = resolver.displayOrientation(for: .coronal)
        #expect(coronal.isUnknown == false)
        #expect(coronal.trailing == "R")
    }

    @Test
    func nrrdOrientationFrameFromSpaceDirections() throws {
        let data = TestMIQFactory.makeNrrd(width: 4, height: 3, depth: 2, datatype: .uint8)
        let url = Self.tempURL(suffix: ".nrrd")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let image = try MIQParser().parse(url: url)

        #expect(image.header.orientationFrame?.source == .nrrdSpaceDirections)
        #expect(image.header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: true),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    // MARK: - Segmentation colouring

    @Test
    func segmentationOffModeReturnsNilLut() throws {
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: [0, 1, 2, 3])
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let offOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .off)
        #expect(volume.buildSegmentationLut(options: offOptions) == nil)
    }

    @Test
    func segmentationFreeSurferAsegColorIsCanonical() throws {
        // White matter (label 2) must render (245,245,245) in auto mode
        let labels: [Int] = [0, 2, 3, 41, 42, 10, 11, 17, 251]  // enough FS labels + signature
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: labels)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        let lut = try #require(volume.buildSegmentationLut(options: autoOptions))
        let color = lut.lookup(2)
        #expect(color == (245, 245, 245))
    }

    @Test
    func segmentationGenericTissueMappingGetsRandomNotFreeSurfer() throws {
        // {1, 2, 3} has no FreeSurfer signature labels → random palette
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: [0, 1, 2, 3])
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        let lut = try #require(volume.buildSegmentationLut(options: autoOptions))
        // In random mode, label 2 should NOT be the FreeSurfer white-matter color (245,245,245)
        // (since the file has no FreeSurfer signature labels, it gets random colours)
        #expect(lut.kind == .random)
    }

    @Test
    func segmentationBinaryMaskRendersWhite() throws {
        // Single non-zero label across the whole volume → monochromeWhite
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .uint8, labels: [0, 5])
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        let lut = try #require(volume.buildSegmentationLut(options: autoOptions))
        #expect(lut.kind == .monochromeWhite)
        let color = lut.lookup(5)
        #expect(color == (255, 255, 255))
    }

    @Test
    func segmentationMultiLabelWhereCenterShowsOneLabel() throws {
        // Center slice shows only 1 label, but the full volume has 2 → coloured, not white
        let data = TestMIQFactory.makeNiiLabelsWithOffCenterSecondLabel(
            width: 8, height: 8, depth: 8, primaryLabel: 5, secondLabel: 7
        )
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        let lut = try #require(volume.buildSegmentationLut(options: autoOptions))
        // Must be random (not white), since it's multi-label
        #expect(lut.kind == .random)
    }

    @Test
    func segmentationFloatLabelMapDetectedSameAsIntegerEquivalent() throws {
        // A label map stored as float32 with integral values must be detected and
        // coloured identically to the int16 equivalent.
        let labelsFS: [Int] = [0, 2, 3, 41, 42, 10, 11, 17, 251]
        let intData = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: labelsFS)
        let floatData = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .float32, labels: labelsFS)
        let intImage = try MIQParser().parseNifti(intData)
        let floatImage = try MIQParser().parseNifti(floatData)
        let intLut = MIQVolume(image: intImage).buildSegmentationLut(
            options: RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto))
        let floatLut = MIQVolume(image: floatImage).buildSegmentationLut(
            options: RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto))
        #expect(intLut != nil)
        #expect(floatLut != nil)
        #expect(intLut!.kind == floatLut!.kind)
    }

    @Test
    func segmentationIntensityImageUnaffected() throws {
        // Dense uint8 anatomical spans 0..254 → more than 160 distinct → nil LUT
        let data = TestMIQFactory.makeNii(width: 16, height: 16, depth: 16, datatype: .uint8)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        #expect(volume.buildSegmentationLut(options: autoOptions) == nil)
    }

    @Test
    func segmentationInt16CTIntensityImageUnaffected() throws {
        // int16 CT values span a wide range of signed integers → not label-like
        let data = TestMIQFactory.makeNii(width: 8, height: 8, depth: 8, datatype: .int16)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        // The factory voxel values are i % 1024 which spans 0..1023 → 161+ distinct
        #expect(volume.buildSegmentationLut(options: autoOptions) == nil)
    }

    @Test
    func segmentationRandomModeSkipsFreeSurferDetection() throws {
        // Even with FreeSurfer labels, .random forces random palette
        let labels: [Int] = [0, 2, 3, 41, 42, 10, 11, 17, 251]
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: labels)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let randomOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .random)
        let lut = try #require(volume.buildSegmentationLut(options: randomOptions))
        #expect(lut.kind == .random)
    }

    @Test
    func segmentationNonIdentityScalingIsGrayscale() throws {
        // scl_slope != 0 or != 1 → intensity, not labels
        let data = TestMIQFactory.makeNiiLabels(
            width: 8, height: 8, depth: 8, datatype: .int16,
            labels: [0, 1, 2, 3], sclSlope: 2.0
        )
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        #expect(volume.buildSegmentationLut(options: autoOptions) == nil)
    }

    @Test
    func segmentationSliceIsRGBWhenLutActive() throws {
        let labels: [Int] = [0, 2, 3, 41, 42, 10, 11, 17, 251]
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: labels)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        let preview = volume.centerPreview(options: autoOptions)
        // All planes should be RGB (not grayscale) when LUT is active
        #expect(preview.segmentationLut != nil)
        for plane in SlicePlane.allCases {
            if case .rgb = preview.slices[plane]! {
                // expected
            } else {
                Issue.record("Expected RGB slice for plane \(plane) when segmentation LUT is active")
            }
        }
        // windowBounds is nil when LUT is active
        #expect(preview.windowBounds == nil)
    }

    @Test
    func segmentationMaxLabelsThresholdIsRespected() throws {
        // Use a tiny maxLabels so a fixture with just 3 foreground labels exceeds it
        let labels: [Int] = [0, 1, 2, 3]
        let data = TestMIQFactory.makeNiiLabels(width: 8, height: 8, depth: 8, datatype: .int16, labels: labels)
        let image = try MIQParser().parseNifti(data)
        let volume = MIQVolume(image: image)
        let autoOptions = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, segmentationColoring: .auto)
        // With maxLabels: 2 (background+1 foreground allowed), 3 foreground labels → nil
        #expect(volume.buildSegmentationLut(options: autoOptions, maxLabels: 2) == nil)
        // With maxLabels: 5, it should succeed
        #expect(volume.buildSegmentationLut(options: autoOptions, maxLabels: 5) != nil)
    }
}

private enum TestMIQFactory {
    static func makeNii(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        pixdim: [Float] = [1, 1, 1, 1],
        volumes: Int = 1
    ) -> Data {
        let headerSize = 348
        let voxOffset = 352
        var bytes = [UInt8](repeating: 0, count: voxOffset)

        write(Int32(headerSize), to: &bytes, at: 0)

        // ndim 3 (+ dim[4] = 1) when volumes == 1 keeps output byte-identical to
        // before; ndim 4 with dim[4] = volumes for the 4D case.
        write(Int16(volumes > 1 ? 4 : 3), to: &bytes, at: 40)
        write(Int16(width), to: &bytes, at: 42)
        write(Int16(height), to: &bytes, at: 44)
        write(Int16(depth), to: &bytes, at: 46)
        write(Int16(volumes), to: &bytes, at: 48)

        write(datatype.rawValue, to: &bytes, at: 70)
        write(Int16(datatype.bytesPerVoxel * 8), to: &bytes, at: 72)

        for idx in 0..<4 {
            let value = pixdim[idx]
            write(value, to: &bytes, at: 76 + idx * 4)
        }

        write(Float32(voxOffset), to: &bytes, at: 108)
        write(Float32(1), to: &bytes, at: 112)
        write(Float32(0), to: &bytes, at: 116)
        write(Int16(1), to: &bytes, at: 252)
        write(Int16(1), to: &bytes, at: 254)

        let voxelCount = width * height * depth * max(1, volumes)
        var payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)

        for i in 0..<voxelCount {
            switch datatype {
            case .uint8:
                payload[i] = UInt8(i % 255)
            case .int16:
                var value = Int16(i % 1024).littleEndian
                withUnsafeBytes(of: &value) { src in
                    payload.replaceSubrange(i * 2..<(i * 2 + 2), with: src)
                }
            default:
                payload[i * datatype.bytesPerVoxel] = UInt8(i % 255)
            }
        }

        return Data(bytes + payload)
    }

    /// NIfTI-1 fixture with explicit sform/qform field values, for orientation-frame tests.
    /// `qfac` is written to pixdim[0]. Pass `nil` rows to leave them zero (degenerate sform).
    static func makeNiiWithAffines(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        sformCode: Int16,
        srowX: [Float],
        srowY: [Float],
        srowZ: [Float],
        qformCode: Int16,
        quaternB: Float,
        quaternC: Float,
        quaternD: Float,
        qfac: Float
    ) -> Data {
        let headerSize = 348
        let voxOffset = 352
        var bytes = [UInt8](repeating: 0, count: voxOffset)

        write(Int32(headerSize), to: &bytes, at: 0)

        write(Int16(3), to: &bytes, at: 40)
        write(Int16(width), to: &bytes, at: 42)
        write(Int16(height), to: &bytes, at: 44)
        write(Int16(depth), to: &bytes, at: 46)
        write(Int16(1), to: &bytes, at: 48)

        write(datatype.rawValue, to: &bytes, at: 70)
        write(Int16(datatype.bytesPerVoxel * 8), to: &bytes, at: 72)

        let pixdim: [Float] = [qfac, 1, 1, 1]
        for idx in 0..<4 {
            write(pixdim[idx], to: &bytes, at: 76 + idx * 4)
        }

        write(Float32(voxOffset), to: &bytes, at: 108)
        write(Float32(1), to: &bytes, at: 112)
        write(Float32(0), to: &bytes, at: 116)
        write(qformCode, to: &bytes, at: 252)
        write(sformCode, to: &bytes, at: 254)
        write(quaternB, to: &bytes, at: 256)
        write(quaternC, to: &bytes, at: 260)
        write(quaternD, to: &bytes, at: 264)
        for idx in 0..<4 {
            write(srowX[safe: idx] ?? 0, to: &bytes, at: 280 + idx * 4)
            write(srowY[safe: idx] ?? 0, to: &bytes, at: 296 + idx * 4)
            write(srowZ[safe: idx] ?? 0, to: &bytes, at: 312 + idx * 4)
        }

        let voxelCount = width * height * depth
        let payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)
        return Data(bytes + payload)
    }

    /// MGH fixture with goodRAS=1 and explicit direction-cosine matrix columns.
    static func makeMghWithDirectionCosines(
        width: Int,
        height: Int,
        depth: Int,
        frames: Int,
        datatype: MIQDatatype,
        xr: Float, xa: Float, xs: Float,
        yr: Float, ya: Float, ys: Float,
        zr: Float, za: Float, zs: Float
    ) -> Data {
        let headerSize = 284
        var bytes = [UInt8](repeating: 0, count: headerSize)

        writeBE(Int32(1), to: &bytes, at: 0)
        writeBE(Int32(width), to: &bytes, at: 4)
        writeBE(Int32(height), to: &bytes, at: 8)
        writeBE(Int32(depth), to: &bytes, at: 12)
        writeBE(Int32(frames), to: &bytes, at: 16)
        writeBE(mghTypeCode(for: datatype), to: &bytes, at: 20)
        writeBE(Int32(0), to: &bytes, at: 24)
        writeBE(Int16(1), to: &bytes, at: 28) // goodRAS

        // Voxel sizes at 30/34/38 (defaults to 1.0).
        writeBE(Float32(1), to: &bytes, at: 30)
        writeBE(Float32(1), to: &bytes, at: 34)
        writeBE(Float32(1), to: &bytes, at: 38)

        writeBE(xr, to: &bytes, at: 42)
        writeBE(xa, to: &bytes, at: 46)
        writeBE(xs, to: &bytes, at: 50)
        writeBE(yr, to: &bytes, at: 54)
        writeBE(ya, to: &bytes, at: 58)
        writeBE(ys, to: &bytes, at: 62)
        writeBE(zr, to: &bytes, at: 66)
        writeBE(za, to: &bytes, at: 70)
        writeBE(zs, to: &bytes, at: 74)

        let voxelCount = width * height * depth * max(1, frames)
        let payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)
        return Data(bytes + payload)
    }

    static func makeNii2(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        pixdim: [Double] = [1, 1, 1, 1]
    ) -> Data {
        let headerSize = 540
        let voxOffset = 544
        var bytes = [UInt8](repeating: 0, count: voxOffset)

        write(Int32(headerSize), to: &bytes, at: 0)
        // magic: "n+2\0\r\n\x1a\n"
        let magic: [UInt8] = [0x6E, 0x2B, 0x32, 0x00, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.replaceSubrange(4..<12, with: magic)

        write(datatype.rawValue, to: &bytes, at: 12)
        write(Int16(datatype.bytesPerVoxel * 8), to: &bytes, at: 14)

        write(Int64(3), to: &bytes, at: 16)
        write(Int64(width), to: &bytes, at: 24)
        write(Int64(height), to: &bytes, at: 32)
        write(Int64(depth), to: &bytes, at: 40)
        write(Int64(1), to: &bytes, at: 48)

        for idx in 0..<4 {
            write(pixdim[idx], to: &bytes, at: 104 + idx * 8)
        }

        write(Int64(voxOffset), to: &bytes, at: 168)
        write(Double(1), to: &bytes, at: 176)
        write(Double(0), to: &bytes, at: 184)
        write(Int32(1), to: &bytes, at: 344)
        write(Int32(1), to: &bytes, at: 348)

        let voxelCount = width * height * depth
        var payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)
        for i in 0..<voxelCount {
            switch datatype {
            case .uint8:
                payload[i] = UInt8(i % 255)
            case .int16:
                var value = Int16(i % 1024).littleEndian
                withUnsafeBytes(of: &value) { src in
                    payload.replaceSubrange(i * 2..<(i * 2 + 2), with: src)
                }
            default:
                payload[i * datatype.bytesPerVoxel] = UInt8(i % 255)
            }
        }

        return Data(bytes + payload)
    }

    static func makeMgh(
        width: Int,
        height: Int,
        depth: Int,
        frames: Int,
        datatype: MIQDatatype
    ) -> Data {
        let headerSize = 284
        var bytes = [UInt8](repeating: 0, count: headerSize)

        writeBE(Int32(1), to: &bytes, at: 0) // version
        writeBE(Int32(width), to: &bytes, at: 4)
        writeBE(Int32(height), to: &bytes, at: 8)
        writeBE(Int32(depth), to: &bytes, at: 12)
        writeBE(Int32(frames), to: &bytes, at: 16)
        writeBE(mghTypeCode(for: datatype), to: &bytes, at: 20)
        writeBE(Int32(0), to: &bytes, at: 24) // dof
        writeBE(Int16(0), to: &bytes, at: 28) // goodRASFlag

        let voxelCount = width * height * depth * max(1, frames)
        var payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)

        for i in 0..<voxelCount {
            switch datatype {
            case .uint8:
                payload[i] = UInt8(i % 255)
            case .int16:
                var value = Int16(i % 1024).bigEndian
                withUnsafeBytes(of: &value) { src in
                    payload.replaceSubrange(i * 2..<(i * 2 + 2), with: src)
                }
            case .int32:
                var value = Int32(i % 4096).bigEndian
                withUnsafeBytes(of: &value) { src in
                    payload.replaceSubrange(i * 4..<(i * 4 + 4), with: src)
                }
            case .float32:
                let f = Float32(i % 255)
                var raw = f.bitPattern.bigEndian
                withUnsafeBytes(of: &raw) { src in
                    payload.replaceSubrange(i * 4..<(i * 4 + 4), with: src)
                }
            default:
                payload[i * datatype.bytesPerVoxel] = UInt8(i % 255)
            }
        }

        return Data(bytes + payload)
    }

    static func makeMif(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        layout: [Int] = [0, 1, 2],
        layoutTokens: [String]? = nil
    ) -> Data {
        if let layoutTokens {
            return makeMifWithLayoutTokens(
                width: width,
                height: height,
                depth: depth,
                datatype: datatype,
                layoutTokens: layoutTokens
            )
        }

        let voxelCount = width * height * depth
        var payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)

        let axisLayout = try! MIFAxisLayout(dim: [width, height, depth], layout: layout)
        let baseElementIndex = axisLayout.baseElementIndex
        let elementStrides = axisLayout.rawStrides

        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let value = x + 10 * y + 100 * z
                    let voxelIndex = baseElementIndex
                        + x * elementStrides[0]
                        + y * elementStrides[1]
                        + z * elementStrides[2]

                    switch datatype {
                    case .uint8:
                        payload[voxelIndex] = UInt8(clamping: value)
                    case .int16:
                        var encoded = Int16(clamping: value).littleEndian
                        withUnsafeBytes(of: &encoded) { src in
                            payload.replaceSubrange(voxelIndex * 2..<(voxelIndex * 2 + 2), with: src)
                        }
                    default:
                        payload[voxelIndex * datatype.bytesPerVoxel] = UInt8(clamping: value)
                    }
                }
            }
        }

        let datatypeLabel = mifDatatypeLabel(for: datatype)
        var offset = 0
        var header = ""
        while true {
            header = """
mrtrix image
dim: \(width),\(height),\(depth)
vox: 1.0,1.0,1.0
layout: \(mifLayoutLabel(layout))
datatype: \(datatypeLabel)
file: . \(offset)
END
"""
            let newOffset = header.utf8.count
            if newOffset == offset {
                break
            }
            offset = newOffset
        }

        return Data(header.utf8 + payload)
    }

    private static func makeMifWithLayoutTokens(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        layoutTokens: [String]
    ) -> Data {
        let components = parseLayoutTokens(layoutTokens)
        let dims = [width, height, depth]
        let voxelCount = width * height * depth
        var payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)

        let sortedAxes = (0..<components.count).sorted { components[$0].order < components[$1].order }
        var elementStrides = Array(repeating: 0, count: components.count)
        var stride = 1
        for axis in sortedAxes {
            let sign = components[axis].reversed ? -1 : 1
            elementStrides[axis] = sign * stride
            stride *= dims[axis]
        }

        var baseElementIndex = 0
        for axis in 0..<components.count where elementStrides[axis] < 0 {
            baseElementIndex += (dims[axis] - 1) * abs(elementStrides[axis])
        }

        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let value = x + 10 * y + 100 * z
                    let voxelIndex = baseElementIndex
                        + x * elementStrides[0]
                        + y * elementStrides[1]
                        + z * elementStrides[2]

                    switch datatype {
                    case .uint8:
                        payload[voxelIndex] = UInt8(clamping: value)
                    case .int16:
                        var encoded = Int16(clamping: value).littleEndian
                        withUnsafeBytes(of: &encoded) { src in
                            payload.replaceSubrange(voxelIndex * 2..<(voxelIndex * 2 + 2), with: src)
                        }
                    default:
                        payload[voxelIndex * datatype.bytesPerVoxel] = UInt8(clamping: value)
                    }
                }
            }
        }

        let datatypeLabel = mifDatatypeLabel(for: datatype)
        let layoutLabel = layoutTokens.joined(separator: ",")
        var offset = 0
        var header = ""
        while true {
            header = """
mrtrix image
dim: \(width),\(height),\(depth)
vox: 1.0,1.0,1.0
layout: \(layoutLabel)
datatype: \(datatypeLabel)
file: . \(offset)
END
"""
            let newOffset = header.utf8.count
            if newOffset == offset {
                break
            }
            offset = newOffset
        }

        return Data(header.utf8 + payload)
    }

    static func makeNrrd(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        space: String = "right-anterior-superior"
    ) -> Data {
        let typeLabel = nrrdTypeLabel(for: datatype)
        let headerLines = [
            "NRRD0004",
            "type: \(typeLabel)",
            "dimension: 3",
            "space: \(space)",
            "sizes: \(width) \(height) \(depth)",
            "space directions: (1,0,0) (0,1,0) (0,0,1)",
            "kinds: domain domain domain",
            "endian: little",
            "encoding: raw",
            "space origin: (0,0,0)"
        ]
        let header = headerLines.joined(separator: "\n") + "\n\n"

        let voxelCount = width * height * depth
        var payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)
        for i in 0..<voxelCount {
            switch datatype {
            case .uint8:
                payload[i] = UInt8(i % 255)
            case .int16:
                var encoded = Int16(i % 1024).littleEndian
                withUnsafeBytes(of: &encoded) { src in
                    payload.replaceSubrange(i * 2..<(i * 2 + 2), with: src)
                }
            default:
                payload[i * datatype.bytesPerVoxel] = UInt8(i % 255)
            }
        }

        return Data(header.utf8) + Data(payload)
    }

    /// NIfTI fixture whose voxels cycle through `labels`, so every label value
    /// appears uniformly across the volume (including all three center slices).
    /// `sclSlope` defaults to 1 (identity); pass a non-identity value to test
    /// that the scl-slope guard prevents segmentation detection.
    static func makeNiiLabels(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        labels: [Int],
        sclSlope: Float = 1.0
    ) -> Data {
        let headerSize = 348
        let voxOffset = 352
        var bytes = [UInt8](repeating: 0, count: voxOffset)

        write(Int32(headerSize), to: &bytes, at: 0)
        write(Int16(3), to: &bytes, at: 40)
        write(Int16(width), to: &bytes, at: 42)
        write(Int16(height), to: &bytes, at: 44)
        write(Int16(depth), to: &bytes, at: 46)
        write(Int16(1), to: &bytes, at: 48)
        write(datatype.rawValue, to: &bytes, at: 70)
        write(Int16(datatype.bytesPerVoxel * 8), to: &bytes, at: 72)
        for idx in 0..<4 {
            write(Float32(1), to: &bytes, at: 76 + idx * 4)
        }
        write(Float32(voxOffset), to: &bytes, at: 108)
        write(sclSlope, to: &bytes, at: 112)
        write(Float32(0), to: &bytes, at: 116)
        write(Int16(1), to: &bytes, at: 252)
        write(Int16(1), to: &bytes, at: 254)

        let voxelCount = width * height * depth
        var payload = [UInt8](repeating: 0, count: voxelCount * datatype.bytesPerVoxel)
        for i in 0..<voxelCount {
            let label = labels.isEmpty ? 0 : labels[i % labels.count]
            switch datatype {
            case .uint8:
                payload[i] = UInt8(clamping: label)
            case .int16:
                var v = Int16(clamping: label).littleEndian
                withUnsafeBytes(of: &v) { src in
                    payload.replaceSubrange(i * 2..<(i * 2 + 2), with: src)
                }
            case .float32:
                var raw = Float32(label).bitPattern.littleEndian
                withUnsafeBytes(of: &raw) { src in
                    payload.replaceSubrange(i * 4..<(i * 4 + 4), with: src)
                }
            case .int32:
                var v = Int32(clamping: label).littleEndian
                withUnsafeBytes(of: &v) { src in
                    payload.replaceSubrange(i * 4..<(i * 4 + 4), with: src)
                }
            default:
                payload[i * datatype.bytesPerVoxel] = UInt8(clamping: abs(label))
            }
        }
        return Data(bytes + payload)
    }

    /// NIfTI fixture where center slices contain only `primaryLabel`, but one
    /// off-center corner voxel carries `secondLabel`. Used to verify that a
    /// single-label center sample triggers the full-volume binary confirm and
    /// correctly detects multi-label rather than committing to white.
    ///
    /// For an 8×8×8 volume: center indices are (4,4,4). Voxel (0,0,0) is not on
    /// any center slice, so placing `secondLabel` there makes the center sample
    /// look binary while the full scan reveals two labels.
    static func makeNiiLabelsWithOffCenterSecondLabel(
        width: Int,
        height: Int,
        depth: Int,
        primaryLabel: Int,
        secondLabel: Int
    ) -> Data {
        let headerSize = 348
        let voxOffset = 352
        var bytes = [UInt8](repeating: 0, count: voxOffset)

        write(Int32(headerSize), to: &bytes, at: 0)
        write(Int16(3), to: &bytes, at: 40)
        write(Int16(width), to: &bytes, at: 42)
        write(Int16(height), to: &bytes, at: 44)
        write(Int16(depth), to: &bytes, at: 46)
        write(Int16(1), to: &bytes, at: 48)
        write(Int16(MIQDatatype.int16.rawValue), to: &bytes, at: 70)
        write(Int16(16), to: &bytes, at: 72)
        for idx in 0..<4 {
            write(Float32(1), to: &bytes, at: 76 + idx * 4)
        }
        write(Float32(voxOffset), to: &bytes, at: 108)
        write(Float32(1), to: &bytes, at: 112)
        write(Float32(0), to: &bytes, at: 116)
        write(Int16(1), to: &bytes, at: 252)
        write(Int16(1), to: &bytes, at: 254)

        let voxelCount = width * height * depth
        // Fill all voxels with primaryLabel
        var payload = [UInt8](repeating: 0, count: voxelCount * 2)
        for i in 0..<voxelCount {
            var v = Int16(clamping: primaryLabel).littleEndian
            withUnsafeBytes(of: &v) { src in
                payload.replaceSubrange(i * 2..<(i * 2 + 2), with: src)
            }
        }
        // Place secondLabel at (0,0,0) — not on any center slice for an 8x8x8 volume
        var v2 = Int16(clamping: secondLabel).littleEndian
        withUnsafeBytes(of: &v2) { src in
            payload.replaceSubrange(0..<2, with: src)
        }
        return Data(bytes + payload)
    }

    private static func nrrdTypeLabel(for datatype: MIQDatatype) -> String {
        switch datatype {
        case .uint8: return "uint8"
        case .int8: return "int8"
        case .uint16: return "uint16"
        case .int16: return "int16"
        case .uint32: return "uint32"
        case .int32: return "int32"
        case .float32: return "float"
        case .float64: return "double"
        case .rgb24, .rgba32: return "uint8"
        }
    }

    private static func parseLayoutTokens(_ tokens: [String]) -> [(order: Int, reversed: Bool)] {
        var result: [(order: Int, reversed: Bool)] = []
        result.reserveCapacity(tokens.count)

        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            precondition(!trimmed.isEmpty, "layout token must not be empty")

            var reversed = false
            var digits = trimmed
            if let first = trimmed.first {
                if first == "-" {
                    reversed = true
                    digits = String(trimmed.dropFirst())
                } else if first == "+" {
                    digits = String(trimmed.dropFirst())
                }
            }

            let order = Int(digits)!
            result.append((order: order, reversed: reversed))
        }

        precondition(Set(result.map { $0.order }).count == result.count, "layout ranks must be unique")
        return result
    }

    private static func mifLayoutLabel(_ layout: [Int]) -> String {
        layout.map { $0 >= 0 ? "+\($0)" : "\($0)" }.joined(separator: ",")
    }

    private static func mghTypeCode(for datatype: MIQDatatype) -> Int32 {
        switch datatype {
        case .uint8:
            return 0
        case .int32:
            return 1
        case .float32:
            return 3
        case .int16:
            return 4
        default:
            return 0
        }
    }

    private static func mifDatatypeLabel(for datatype: MIQDatatype) -> String {
        switch datatype {
        case .uint8:
            return "UInt8"
        case .int16:
            return "Int16LE"
        case .uint16:
            return "UInt16LE"
        case .int32:
            return "Int32LE"
        case .uint32:
            return "UInt32LE"
        case .float32:
            return "Float32LE"
        case .float64:
            return "Float64LE"
        case .int8:
            return "Int8"
        case .rgb24, .rgba32:
            return "UInt8"
        }
    }

    private static func write(_ value: Int64, to bytes: inout [UInt8], at offset: Int) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { src in
            bytes.replaceSubrange(offset..<(offset + 8), with: src)
        }
    }

    private static func write(_ value: Double, to bytes: inout [UInt8], at offset: Int) {
        var raw = value.bitPattern.littleEndian
        withUnsafeBytes(of: &raw) { src in
            bytes.replaceSubrange(offset..<(offset + 8), with: src)
        }
    }

    private static func write(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { src in
            bytes.replaceSubrange(offset..<(offset + 2), with: src)
        }
    }

    private static func write(_ value: Int32, to bytes: inout [UInt8], at offset: Int) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { src in
            bytes.replaceSubrange(offset..<(offset + 4), with: src)
        }
    }

    private static func write(_ value: Float32, to bytes: inout [UInt8], at offset: Int) {
        var raw = value.bitPattern.littleEndian
        withUnsafeBytes(of: &raw) { src in
            bytes.replaceSubrange(offset..<(offset + 4), with: src)
        }
    }

    private static func writeBE(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { src in
            bytes.replaceSubrange(offset..<(offset + 2), with: src)
        }
    }

    private static func writeBE(_ value: Int32, to bytes: inout [UInt8], at offset: Int) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { src in
            bytes.replaceSubrange(offset..<(offset + 4), with: src)
        }
    }

    private static func writeBE(_ value: Float32, to bytes: inout [UInt8], at offset: Int) {
        var raw = value.bitPattern.bigEndian
        withUnsafeBytes(of: &raw) { src in
            bytes.replaceSubrange(offset..<(offset + 4), with: src)
        }
    }
}
