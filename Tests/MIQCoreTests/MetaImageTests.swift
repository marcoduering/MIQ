import Foundation
import Testing
@testable import MIQCore

extension TestMIQFactory {
    /// MetaImage (`.mha`) with the fields in the order ITK's `MetaImageIO` writes
    /// them. Elements are `sampleValue(index:)` in storage order, channels
    /// interleaved per voxel. `transform` is the `TransformMatrix` value; `nil`
    /// writes the identity for the image's dimensionality, `omitTransform` leaves
    /// the field out.
    static func makeMetaImage(
        sizes: [Int],
        channels: Int = 1,
        datatype: MIQDatatype,
        compressed: Bool = false,
        bigEndian: Bool = false,
        transform: String? = nil,
        omitTransform: Bool = false,
        spacing: String? = nil,
        dataFile: String = "LOCAL",
        lineEnding: String = "\n",
        extraFields: [String] = []
    ) throws -> Data {
        let n = sizes.count
        let elementCount = sizes.reduce(1, *) * channels
        var raw = [UInt8](repeating: 0, count: elementCount * datatype.bytesPerVoxel)
        for i in 0..<elementCount {
            encodeSample(sampleValue(index: i, datatype: datatype), at: i, datatype: datatype,
                         bigEndian: bigEndian, into: &raw)
        }
        let payload = compressed ? try TestZlib.zlib(Data(raw)) : Data(raw)

        let identity = (0..<n * n).map { $0 / n == $0 % n ? "1" : "0" }.joined(separator: " ")
        let lines: [String?] = [
            "ObjectType = Image",
            "NDims = \(n)",
            "BinaryData = True",
            "BinaryDataByteOrderMSB = \(bigEndian ? "True" : "False")",
            "CompressedData = \(compressed ? "True" : "False")",
            compressed ? "CompressedDataSize = \(payload.count)" : nil,
            omitTransform ? nil : "TransformMatrix = \(transform ?? identity)",
            "Offset = " + Array(repeating: "0", count: n).joined(separator: " "),
            "AnatomicalOrientation = RAI",
            "ElementSpacing = " + (spacing ?? Array(repeating: "1", count: n).joined(separator: " ")),
            channels > 1 ? "ElementNumberOfChannels = \(channels)" : nil,
            "DimSize = " + sizes.map(String.init).joined(separator: " "),
            "ElementType = \(metaImageTypeLabel(for: datatype))",
        ]
        let header = (lines.compactMap { $0 } + extraFields + ["ElementDataFile = \(dataFile)"])
            .joined(separator: lineEnding) + lineEnding
        return Data(header.utf8) + payload
    }

    private static func metaImageTypeLabel(for datatype: MIQDatatype) -> String {
        switch datatype {
        case .int8: return "MET_CHAR"
        case .uint8, .rgb24, .rgba32: return "MET_UCHAR"
        case .int16: return "MET_SHORT"
        case .uint16: return "MET_USHORT"
        case .int32: return "MET_INT"
        case .uint32: return "MET_UINT"
        case .int64: return "MET_LONG_LONG"
        case .uint64: return "MET_ULONG_LONG"
        case .float32: return "MET_FLOAT"
        case .float64: return "MET_DOUBLE"
        }
    }
}

struct MetaImageTests {

    private static func sample(_ index: Int, _ datatype: MIQDatatype) -> Float {
        Float(TestMIQFactory.sampleValue(index: index, datatype: datatype))
    }

    /// Every voxel of a single-channel image against the sample at its x-fastest index.
    private static func expectVoxels(_ image: MIQImage, sizes: [Int], datatype: MIQDatatype) {
        let volume = MIQVolume(image: image)
        let (w, h) = (sizes[0], sizes[1])
        let d = sizes[safe: 2] ?? 1
        let v = sizes[safe: 3] ?? 1
        for t in 0..<v { for z in 0..<d { for y in 0..<h { for x in 0..<w {
            let index = x + w * (y + h * (z + d * t))
            #expect(volume.voxel(x: x, y: y, z: z, t: t) == sample(index, datatype), "(\(x),\(y),\(z),\(t))")
        } } } }
    }

    private static func tempURL(suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString + suffix)
    }

    // MARK: - Payload

    @Test func parsesRawFileThroughDispatch() throws {
        let url = Self.tempURL(suffix: ".mha")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestMIQFactory.makeMetaImage(sizes: [5, 4, 3], datatype: .int16, spacing: "0.5 2 3").write(to: url)

        #expect(MIQFileKind(url: url) == .mha)
        let image = try MIQParser().parse(url: url)
        #expect(image.header.dimensions == [5, 4, 3, 1])
        #expect(image.header.datatype == .int16)
        #expect(image.header.pixdim == [1, 0.5, 2, 3])
        #expect(image.header.formatLabel == nil)
        #expect(image.payloadElementStrides == nil)
        Self.expectVoxels(image, sizes: [5, 4, 3], datatype: .int16)
    }

    @Test(arguments: [MIQDatatype.uint8, .int8, .int16, .uint16, .int32, .uint32, .float32, .float64, .int64, .uint64])
    func compressedAndBigEndianDecodeLikeRaw(datatype: MIQDatatype) throws {
        let sizes = [4, 3, 2]
        for (compressed, bigEndian) in [(false, true), (true, false), (true, true)] {
            let data = try TestMIQFactory.makeMetaImage(sizes: sizes, datatype: datatype,
                                                        compressed: compressed, bigEndian: bigEndian)
            let image = try MIQParser().parseMetaImage(data)
            #expect(image.header.littleEndian == !bigEndian)
            #expect(image.header.formatLabel == (compressed ? "Compressed MetaImage" : nil))
            Self.expectVoxels(image, sizes: sizes, datatype: datatype)
        }
    }

    @Test func crlfHeaderParses() throws {
        let data = try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, lineEnding: "\r\n")
        Self.expectVoxels(try MIQParser().parseMetaImage(data), sizes: [4, 3, 2], datatype: .uint8)
    }

    @Test func fourDimensionalImageHasVolumes() throws {
        let sizes = [4, 3, 2, 3]
        let image = try MIQParser().parseMetaImage(
            try TestMIQFactory.makeMetaImage(sizes: sizes, datatype: .float32, compressed: true))
        #expect(image.header.dimensions == [4, 3, 2, 3])
        #expect(image.payloadElementStrides == nil)
        Self.expectVoxels(image, sizes: sizes, datatype: .float32)
    }

    @Test func twoDimensionalImageIsOneSlice() throws {
        let image = try MIQParser().parseMetaImage(try TestMIQFactory.makeMetaImage(sizes: [5, 4], datatype: .uint16))
        #expect(image.header.dimensions == [5, 4, 1, 1])
        #expect(image.header.orientationFrame == nil)
        Self.expectVoxels(image, sizes: [5, 4], datatype: .uint16)
    }

    @Test func threeOrFourByteChannelsAreColor() throws {
        for (channels, expected) in [(3, MIQDatatype.rgb24), (4, .rgba32)] {
            let image = try MIQParser().parseMetaImage(
                try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], channels: channels, datatype: .uint8))
            #expect(image.header.datatype == expected)
            #expect(image.header.volumes == 1)
            #expect(image.payloadElementStrides == nil)
        }
    }

    @Test func otherChannelsAreVolumes() throws {
        let (w, h, d, c) = (4, 3, 2, 3)
        let image = try MIQParser().parseMetaImage(
            try TestMIQFactory.makeMetaImage(sizes: [w, h, d], channels: c, datatype: .float32))
        #expect(image.header.dimensions == [w, h, d, c])
        #expect(image.payloadElementStrides == [c, c * w, c * w * h, 1])
        let volume = MIQVolume(image: image)
        for t in 0..<c { for z in 0..<d { for y in 0..<h { for x in 0..<w {
            #expect(volume.voxel(x: x, y: y, z: z, t: t) == Self.sample(t + c * (x + w * (y + h * z)), .float32))
        } } } }
    }

    // MARK: - Orientation

    @Test func identityTransformIsLps() throws {
        let image = try MIQParser().parseMetaImage(try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8))
        #expect(image.header.orientationFrame?.source == .metaImageTransform)
        #expect(image.header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: false),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: false),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
        #expect(image.header.sformCode == 1)
    }

    /// Each run of three values is one storage axis's direction (ITK's convention),
    /// so axis 0 → +S, axis 1 → +L, axis 2 → +P.
    @Test func transformRunsAreAxisDirections() throws {
        let image = try MIQParser().parseMetaImage(
            try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, transform: "0 0 1 1 0 0 0 1 0"))
        #expect(image.header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .superiorInferior, positive: true),
            StorageAxisOrientation(axis: .rightLeft, positive: false),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: false)
        ])
    }

    @Test func fourDimensionalTransformUsesSpatialBlock() throws {
        let image = try MIQParser().parseMetaImage(
            try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2, 2], datatype: .uint8,
                                             transform: "-1 0 0 0  0 1 0 0  0 0 1 0  0 0 0 1"))
        #expect(image.header.orientationFrame?.axes == [
            StorageAxisOrientation(axis: .rightLeft, positive: true),
            StorageAxisOrientation(axis: .anteriorPosterior, positive: false),
            StorageAxisOrientation(axis: .superiorInferior, positive: true)
        ])
    }

    @Test func missingTransformBuildsNoFrameButKeepsSpacing() throws {
        let image = try MIQParser().parseMetaImage(
            try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, omitTransform: true, spacing: "2 2 3"))
        #expect(image.header.orientationFrame == nil)
        #expect(image.header.sformCode == 0)
        #expect(image.header.pixdim == [1, 2, 2, 3])
    }

    // MARK: - Rejections

    @Test func rejectsDetachedDataFile() throws {
        let data = try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, dataFile: "image.raw")
        #expect { try MIQParser().parseMetaImage(data) } throws: { error in
            if case MIQError.unsupportedFeature = error { return true } else { return false }
        }
    }

    @Test func rejectsAsciiData() throws {
        let data = try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, extraFields: ["BinaryData = False"])
        #expect { try MIQParser().parseMetaImage(data) } throws: { error in
            if case MIQError.unsupportedFeature = error { return true } else { return false }
        }
    }

    @Test func rejectsFileWithoutElementDataFile() {
        let data = Data("ObjectType = Image\nNDims = 3\nDimSize = 2 2 2\nElementType = MET_UCHAR\n".utf8) + Data(count: 8)
        #expect { try MIQParser().parseMetaImage(data) } throws: { error in
            if case MIQError.malformedFile = error { return true } else { return false }
        }
    }

    @Test func rejectsNDimsMismatch() throws {
        let data = try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, extraFields: ["NDims = 4"])
        #expect { try MIQParser().parseMetaImage(data) } throws: { error in
            if case MIQError.malformedFile = error { return true } else { return false }
        }
    }

    @Test func truncatedPayloadThrows() throws {
        for compressed in [false, true] {
            let data = try TestMIQFactory.makeMetaImage(sizes: [8, 8, 8], datatype: .int16, compressed: compressed)
            #expect(throws: MIQError.self) { try MIQParser().parseMetaImage(data.prefix(data.count - 7)) }
        }
    }

    @Test func intMaxPayloadThrowsWithoutTrapping() {
        let header = """
        ObjectType = Image
        NDims = 3
        DimSize = \(Int.max) 1 1
        ElementType = MET_UCHAR
        ElementDataFile = LOCAL

        """
        #expect(throws: MIQError.self) { try MIQParser().parseMetaImage(Data(header.utf8)) }
    }

    // MARK: - Thumbnail gate

    @Test func headerProbeReadsCompressedData() throws {
        let raw = try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8)
        let zlib = try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, compressed: true)
        let detached = try TestMIQFactory.makeMetaImage(sizes: [4, 3, 2], datatype: .uint8, dataFile: "x.raw")
        #expect(MIQParser.metaImageHasRawPayload(prefix: raw))
        #expect(!MIQParser.metaImageHasRawPayload(prefix: zlib))
        #expect(!MIQParser.metaImageHasRawPayload(prefix: detached))
        #expect(!MIQParser.metaImageHasRawPayload(prefix: Data("not a header".utf8)))
    }

    @Test func largeMetaImageDeclinesUnlessConfirmedRawAndLocal() {
        let kind = MIQFileKind.mha
        #expect(kind.headerDecidesCompression)
        #expect(kind.declinesThumbnail(fileSizeBytes: 101, isLocal: true, thresholdBytes: 100))
        #expect(!kind.declinesThumbnail(fileSizeBytes: 101, isLocal: true, thresholdBytes: 100, hasRawPayload: true))
        #expect(kind.declinesThumbnail(fileSizeBytes: 101, isLocal: false, thresholdBytes: 100, hasRawPayload: true))
    }
}
