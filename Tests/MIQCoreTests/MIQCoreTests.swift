import Foundation
import Testing
@testable import MIQCore

struct MIQCoreTests {
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

        let coronal = volume.centerSlice(plane: .coronal)
        let sagittal = volume.centerSlice(plane: .sagittal)
        let axial = volume.centerSlice(plane: .axial)

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

        #expect(lines.contains(where: { $0.contains("Dimensions: 16 x 8 x 4") }))
        #expect(lines.contains(where: { $0.contains("Datatype: int16") }))
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
        let center = volume.centerSlice(plane: .axial)
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
        let axial = volume.centerSlice(plane: .axial)
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

        let axial = volume.centerSlice(plane: .axial)
        let coronal = volume.centerSlice(plane: .coronal)
        let sagittal = volume.centerSlice(plane: .sagittal)

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
        let axial = volume.centerSlice(plane: .axial)
        let coronal = volume.centerSlice(plane: .coronal)
        let sagittal = volume.centerSlice(plane: .sagittal)

        if case .rgb(let img) = axial {
            #expect(img.width > 0 && img.height > 0)
            #expect(img.pixels.count == img.width * img.height * 3)
        } else {
            Issue.record("expected rgb slice for rgb24 datatype")
        }
        #expect(coronal.width > 0 && coronal.height > 0)
        #expect(sagittal.width > 0 && sagittal.height > 0)

        let lines = MIQMetadata(header: image.header).asDisplayLines()
        #expect(lines.contains(where: { $0.contains("Datatype: rgb24") }))
    }

    @Test
    func parsesNiftiRgba32AndRendersColorSlices() throws {
        let data = TestMIQFactory.makeNii(width: 6, height: 4, depth: 3, datatype: .rgba32)
        let image = try MIQParser().parseNifti(data)

        #expect(image.header.datatype == .rgba32)
        #expect(image.payloadCount == 6 * 4 * 3 * 4)

        let volume = MIQVolume(image: image)
        let axial = volume.centerSlice(plane: .axial)

        if case .rgb(let img) = axial {
            #expect(img.width > 0 && img.height > 0)
            #expect(img.pixels.count == img.width * img.height * 3)
        } else {
            Issue.record("expected rgb slice for rgba32 datatype")
        }

        let lines = MIQMetadata(header: image.header).asDisplayLines()
        #expect(lines.contains(where: { $0.contains("Datatype: rgba32") }))
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
}
