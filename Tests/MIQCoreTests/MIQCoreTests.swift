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
        // Both factory and parser use signed strides + base, so display reads should agree
        // with where the factory wrote — without flipping the value.
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
    func planForRasModeOnCanonicalRasIsIdentity() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .ras)
        #expect((plan.sliceAxis, plan.hAxis, plan.vAxis) == (1, 0, 2))
        #expect(plan.hReversed == false && plan.vReversed == true)
        #expect(plan.labels.leading == "L" && plan.labels.trailing == "R")
        #expect(plan.labels.top == "S" && plan.labels.bottom == "I")
    }

    @Test
    func planForRasModeOnLasStorageFlipsHorizontal() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .ras)
        #expect(plan.hReversed == true)
        #expect(plan.vReversed == true)
        // Labels stay fixed in RAS view regardless of storage orientation.
        #expect(plan.labels.leading == "L" && plan.labels.trailing == "R")
    }

    @Test
    func planForLasModeOnCanonicalRasFlipsHorizontal() throws {
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [0, 1, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .las)
        #expect(plan.hReversed == true)
        #expect(plan.labels.leading == "R" && plan.labels.trailing == "L")
        #expect(plan.labels.top == "S" && plan.labels.bottom == "I")

        // Sagittal labels are the same in RAS and LAS modes.
        let sag = resolver.plan(for: .sagittal, mode: .las)
        #expect(sag.labels.leading == "P" && sag.labels.trailing == "A")
        #expect(sag.labels.top == "S" && sag.labels.bottom == "I")
    }

    @Test
    func planForRasModeRoutesPermutedStorageToCorrectAnatomicalAxis() throws {
        // layout [1, 0, 2] → storage axis 0 anatomically = A-P, axis 1 = R-L.
        let mif = TestMIQFactory.makeMif(width: 4, height: 3, depth: 2, datatype: .uint8, layout: [1, 0, 2])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let image = try MIQParser().parse(url: url)

        let resolver = OrientationResolver(image: image)
        let plan = resolver.plan(for: .coronal, mode: .ras)
        // The RAS coronal slice must slice along the A-P axis (storage 0 here) and
        // walk the R-L axis (storage 1) horizontally — different from the stored
        // mapping which would slice along storage axis 1.
        #expect(plan.sliceAxis == 0)
        #expect(plan.hAxis == 1)
        #expect(plan.vAxis == 2)
        #expect(plan.hReversed == false)
        #expect(plan.vReversed == true)
    }

    @Test
    func reorientFallsBackToStoredWhenAffineUnknown() throws {
        // Both codes zero → no orientation frame → .ras/.las must collapse to .stored.
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
        let ras = resolver.plan(for: .coronal, mode: .ras)
        let las = resolver.plan(for: .coronal, mode: .las)

        #expect(stored.sliceAxis == ras.sliceAxis && stored.hAxis == ras.hAxis && stored.vAxis == ras.vAxis)
        #expect(stored.hReversed == ras.hReversed && stored.vReversed == ras.vReversed)
        #expect(stored.sliceAxis == las.sliceAxis && stored.hAxis == las.hAxis && stored.vAxis == las.vAxis)
        #expect(stored.hReversed == las.hReversed && stored.vReversed == las.vReversed)
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

        let rasOpt = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .ras)
        let lasOpt = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .las)

        #expect(volume.displayOrientation(for: .coronal, options: rasOpt).trailing == "R")
        #expect(volume.displayOrientation(for: .coronal, options: lasOpt).trailing == "L")
        #expect(volume.displayOrientation(for: .axial, options: rasOpt).top == "A")
        #expect(volume.displayOrientation(for: .axial, options: lasOpt).top == "A")
        #expect(volume.displayOrientation(for: .sagittal, options: rasOpt).trailing == "A")
        #expect(volume.displayOrientation(for: .sagittal, options: lasOpt).trailing == "A")
    }

    @Test
    func rasModeOnLasStorageHorizontallyMirrorsStoredPixels() throws {
        // Use a volume with enough x-resolution that mirrored columns map to distinct
        // gray levels after percentile normalization.
        let width = 8, height = 4, depth = 4
        let mif = TestMIQFactory.makeMif(width: width, height: height, depth: depth, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let volume = MIQVolume(image: try MIQParser().parse(url: url))

        let stored = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .stored)
        let ras = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .ras)
        let storedSlice = volume.centerSlice(plane: .coronal, options: stored)
        let rasSlice = volume.centerSlice(plane: .coronal, options: ras)

        guard case .grayscale(let s) = storedSlice, case .grayscale(let r) = rasSlice else {
            Issue.record("expected grayscale slices")
            return
        }
        #expect(s.width == r.width && s.height == r.height)

        // Every row of the RAS slice is the row-wise horizontal mirror of the stored slice.
        for row in 0..<s.height {
            for col in 0..<s.width {
                let mirror = s.width - 1 - col
                #expect(s.pixels[row * s.width + col] == r.pixels[row * r.width + mirror])
            }
        }
    }

    @Test
    func lasModeOnLasStoragePreservesPixels() throws {
        // LAS-stored data viewed in .las mode = no transformation (same plan as .stored).
        let width = 8, height = 4, depth = 4
        let mif = TestMIQFactory.makeMif(width: width, height: height, depth: depth, datatype: .uint8, layoutTokens: ["-0", "+1", "+2"])
        let url = Self.tempURL(suffix: ".mif")
        defer { try? FileManager.default.removeItem(at: url) }
        try mif.write(to: url)
        let volume = MIQVolume(image: try MIQParser().parse(url: url))

        let stored = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .stored)
        let las = RenderingOptions(lowerPercentile: 0, upperPercentile: 100, orientation: .las)
        let storedSlice = volume.centerSlice(plane: .coronal, options: stored)
        let lasSlice = volume.centerSlice(plane: .coronal, options: las)

        guard case .grayscale(let s) = storedSlice, case .grayscale(let l) = lasSlice else {
            Issue.record("expected grayscale slices")
            return
        }
        #expect(s.pixels == l.pixels)
    }

    @Test
    func renderingOptionsHashableIncludesOrientation() {
        let a = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .stored)
        let b = RenderingOptions(lowerPercentile: 2, upperPercentile: 98, orientation: .ras)
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
}

private enum TestMIQFactory {
    static func makeNii(
        width: Int,
        height: Int,
        depth: Int,
        datatype: MIQDatatype,
        pixdim: [Float] = [1, 1, 1, 1]
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
            let value = pixdim[idx]
            write(value, to: &bytes, at: 76 + idx * 4)
        }

        write(Float32(voxOffset), to: &bytes, at: 108)
        write(Float32(1), to: &bytes, at: 112)
        write(Float32(0), to: &bytes, at: 116)
        write(Int16(1), to: &bytes, at: 252)
        write(Int16(1), to: &bytes, at: 254)

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
