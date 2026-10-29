import Foundation

/// ITK MetaImage (`.mha`): a text header of `Key = Value` lines that ends with
/// `ElementDataFile = LOCAL`, followed by the voxels in the same file — raw, or a
/// zlib stream when `CompressedData = True`. The detached `.mhd` + `.raw` pair is
/// not supported (Quick Look grants access to the selected file only).
extension MIQParser {

    private struct MetaImageParsedHeader {
        /// `DimSize`, fastest axis first. Two or three spatial axes, optionally a fourth.
        let sizes: [Int]
        /// `ElementNumberOfChannels`; channels are interleaved per voxel.
        let channels: Int
        /// Scalar type of one channel.
        let elementType: MIQDatatype
        let littleEndian: Bool
        let compressed: Bool
        let compressedSize: Int?
        let spacing: [Float]?
        let origin: [Float]?
        /// `TransformMatrix`, NDims × NDims. Axis i's direction in ITK's LPS world is
        /// the i-th run of NDims values (ITK's `MetaImageIO` reads and writes it so).
        let transform: [Float]?
        /// The `Comment` field.
        let comment: String?
    }

    // MARK: - Public entry points

    func parseMetaImage(_ data: Data) throws -> MIQImage {
        let (fields, payloadIndex) = try splitMetaImageHeader(data: data)
        let meta = try buildMetaImageParsedHeader(fields: fields)

        let payloadBytes = meta.sizes.reduce(1, *) * meta.channels * meta.elementType.bytesPerVoxel
        guard payloadBytes > 0 else { throw MIQError.invalidDimensions }

        let storage: Data
        let payloadOffset: Int
        if meta.compressed {
            var compressed = data[payloadIndex...]
            if let size = meta.compressedSize, size > 0, size < compressed.count {
                compressed = compressed.prefix(size)
            }
            storage = try MIQBinaryReader.inflateZlib(compressed, maxOutputBytes: payloadBytes)
            payloadOffset = 0
        } else {
            storage = data
            payloadOffset = data.distance(from: data.startIndex, to: payloadIndex)
        }
        // Subtraction form: `payloadOffset + payloadBytes` traps when the validated dims
        // product lands on `Int.max`. The offset is 0 for the compressed branch and the
        // header-split index (`<= count`) for raw, so the left side cannot go negative.
        guard storage.count - payloadOffset >= payloadBytes else { throw MIQError.truncatedData }

        return MIQImage(
            header: buildMetaImageMIQHeader(meta: meta, payloadOffset: payloadOffset),
            storage: storage,
            payloadOffset: payloadOffset,
            payloadElementStrides: metaImageStrides(meta: meta)
        )
    }

    // MARK: - Header split

    /// How far the header may run. Real headers are a few hundred bytes; the cap
    /// keeps a file that isn't MetaImage from being scanned in full.
    static let metaImageHeaderProbeBytes = 64 * 1024

    /// Collects `Key = Value` fields (keys lowercased) up to and including the
    /// `ElementDataFile` line, which MetaImage always writes last, and returns
    /// the index right after it, where the payload begins. Walking line by line
    /// stops there, so the payload is never scanned.
    private func splitMetaImageHeader(data: Data) throws -> ([String: String], Data.Index) {
        let limit = data.index(data.startIndex, offsetBy: Swift.min(data.count, Self.metaImageHeaderProbeBytes))
        var fields: [String: String] = [:]
        var lineStart = data.startIndex
        while lineStart < limit {
            let newline = data[lineStart..<limit].firstIndex(of: 0x0A)
            // A line cut off by the probe limit (not by the end of the file) is incomplete.
            if newline == nil, limit < data.endIndex { break }
            let lineEnd = newline ?? limit
            let next = newline.map { $0 + 1 } ?? limit
            let line = String(decoding: data[lineStart..<lineEnd], as: UTF8.self)
            if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "elementdatafile" { return (fields, next) }
            }
            lineStart = next
        }
        throw MIQError.malformedFile("MetaImage header has no ElementDataFile line; file does not appear to be MetaImage format")
    }

    // MARK: - Thumbnail gate

    /// Whether a MetaImage stores its payload raw, judged from the header alone —
    /// the `.mha` counterpart of `nrrdHasRawPayload(at:)`. Any failure (unreadable,
    /// no `ElementDataFile` within the probe, a detached data file) answers `false`.
    public static func metaImageHasRawPayload(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: metaImageHeaderProbeBytes) else { return false }
        return metaImageHasRawPayload(prefix: prefix)
    }

    static func metaImageHasRawPayload(prefix: Data) -> Bool {
        guard let (fields, _) = try? MIQParser().splitMetaImageHeader(data: prefix),
              fields["elementdatafile"]?.lowercased() == "local" else { return false }
        return !metaImageBool(fields["compresseddata"])
    }

    // MARK: - Header fields

    private func buildMetaImageParsedHeader(fields: [String: String]) throws -> MetaImageParsedHeader {
        if let objectType = fields["objecttype"], objectType.lowercased() != "image" {
            throw MIQError.unsupportedFeature("MetaImage object type '\(objectType)' is not an image")
        }
        let dataFile = fields["elementdatafile"] ?? ""
        guard dataFile.lowercased() == "local" else {
            throw MIQError.unsupportedFeature(
                "MetaImage with a separate data file (ElementDataFile = \(dataFile)) is not supported; use a self-contained .mha file"
            )
        }
        if let binary = fields["binarydata"], !Self.metaImageBool(binary) {
            throw MIQError.unsupportedFeature("MetaImage ASCII data (BinaryData = False) is not supported")
        }

        guard let sizesStr = fields["dimsize"] else {
            throw MIQError.malformedFile("MetaImage header is missing required field 'DimSize'")
        }
        let sizes = try parseMetaImageIntList(sizesStr, field: "DimSize")
        guard sizes.allSatisfy({ $0 > 0 }) else { throw MIQError.invalidDimensions }
        if let ndims = fields["ndims"].flatMap({ Int($0) }), ndims != sizes.count {
            throw MIQError.malformedFile("MetaImage NDims = \(ndims) but DimSize lists \(sizes.count) values")
        }
        guard (2...4).contains(sizes.count) else {
            throw MIQError.unsupportedFeature("MetaImage with \(sizes.count) dimensions is not supported (2 to 4 are)")
        }

        let channels = try fields["elementnumberofchannels"].map {
            try parseMetaImageIntList($0, field: "ElementNumberOfChannels")
        }?.first ?? 1
        guard channels >= 1 else { throw MIQError.invalidDimensions }
        if channels > 1, sizes.count == 4 {
            throw MIQError.unsupportedFeature("4D MetaImage with more than one channel per voxel is not supported")
        }

        guard let typeStr = fields["elementtype"] else {
            throw MIQError.malformedFile("MetaImage header is missing required field 'ElementType'")
        }
        let elementType = try parseMetaImageElementType(typeStr)
        try validateDimensionExtent(sizes + [channels], bytesPerVoxel: elementType.bytesPerVoxel)

        let msb = fields["binarydatabyteordermsb"] ?? fields["elementbyteordermsb"]
        let compressedSize = fields["compresseddatasize"].flatMap { Int($0) }
        let spacing = (fields["elementspacing"] ?? fields["elementsize"]).flatMap(parseMetaImageFloatList)
        let origin = (fields["offset"] ?? fields["position"] ?? fields["origin"]).flatMap(parseMetaImageFloatList)
        let transform = (fields["transformmatrix"] ?? fields["rotation"] ?? fields["orientation"])
            .flatMap(parseMetaImageFloatList)
            .flatMap { $0.count == sizes.count * sizes.count ? $0 : nil }

        return MetaImageParsedHeader(
            sizes: sizes,
            channels: channels,
            elementType: elementType,
            littleEndian: !Self.metaImageBool(msb),
            compressed: Self.metaImageBool(fields["compresseddata"]),
            compressedSize: compressedSize,
            spacing: spacing,
            origin: origin,
            transform: transform,
            comment: fields["comment"]
        )
    }

    // MARK: - Image construction

    /// Three uint8 channels are RGB and four RGBA, which MIQ renders in colour as
    /// it stores them (interleaved per voxel). Any other multi-channel image (a
    /// displacement field, say) shows its channels as volumes.
    private func metaImageRendersAsColor(_ meta: MetaImageParsedHeader) -> MIQDatatype? {
        guard meta.elementType == .uint8 else { return nil }
        switch meta.channels {
        case 3: return .rgb24
        case 4: return .rgba32
        default: return nil
        }
    }

    /// Channels shown as volumes are the fastest axis, so the spatial axes step
    /// over them; every other layout is the default x-fastest one.
    private func metaImageStrides(meta: MetaImageParsedHeader) -> [Int]? {
        guard meta.channels > 1, metaImageRendersAsColor(meta) == nil else { return nil }
        let c = meta.channels
        let sx = meta.sizes[0]
        let sy = meta.sizes[1]
        return [c, c * sx, c * sx * sy, 1]
    }

    private func buildMetaImageMIQHeader(meta: MetaImageParsedHeader, payloadOffset: Int) -> MIQHeader {
        let sx = meta.sizes[0]
        let sy = meta.sizes[1]
        let sz = meta.sizes[safe: 2] ?? 1
        let color = metaImageRendersAsColor(meta)
        let nVols = color == nil && meta.channels > 1 ? meta.channels : (meta.sizes[safe: 3] ?? 1)

        let spacing = (0..<3).map { abs(meta.spacing?[safe: $0] ?? 1) }

        var srowX: [Float] = [0, 0, 0, 0]
        var srowY: [Float] = [0, 0, 0, 0]
        var srowZ: [Float] = [0, 0, 0, 0]
        var orientationFrame: OrientationFrame?
        // A 2D image has no third direction to place, so only 3D/4D get a frame;
        // `AnatomicalOrientation` is informational and ignored, as ITK does on read.
        if let transform = meta.transform, meta.sizes.count >= 3 {
            let n = meta.sizes.count
            let origin = meta.origin ?? []
            // LPS → RAS flips the first two world components.
            let toRas: [Float] = [-1, -1, 1]
            var rows: [[Float]] = [[], [], []]
            for world in 0..<3 {
                for axis in 0..<3 {
                    rows[world].append(transform[axis * n + world] * spacing[axis] * toRas[world])
                }
                rows[world].append((origin[safe: world] ?? 0) * toRas[world])
            }
            srowX = rows[0]
            srowY = rows[1]
            srowZ = rows[2]
            orientationFrame = OrientationFrame.from(srowX: srowX, srowY: srowY, srowZ: srowZ,
                                                     source: .metaImageTransform)
        }

        return MIQHeader(
            littleEndian: meta.littleEndian,
            dimensions: [sx, sy, sz, nVols],
            pixdim: [1.0] + spacing,
            datatype: color ?? meta.elementType,
            voxOffset: payloadOffset,
            sclSlope: 1.0,
            sclInter: 0.0,
            qformCode: 0,
            sformCode: orientationFrame != nil ? 1 : 0,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            formatLabel: meta.compressed ? "Compressed MetaImage" : nil,
            orientationFrame: orientationFrame,
            comment: meta.comment.flatMap { Self.headerComment([$0]) }
        )
    }

    // MARK: - Field value parsers

    private static func metaImageBool(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "true" || value == "1"
    }

    /// `MET_LONG`/`MET_ULONG` are 4 bytes in MetaIO (`MET_ValueTypeSize`), not
    /// the platform `long`; ITK writes 64-bit integers as `MET_LONG_LONG`.
    private func parseMetaImageElementType(_ value: String) throws -> MIQDatatype {
        switch value.uppercased() {
        case "MET_CHAR":                    return .int8
        case "MET_UCHAR":                   return .uint8
        case "MET_SHORT":                   return .int16
        case "MET_USHORT":                  return .uint16
        case "MET_INT", "MET_LONG":         return .int32
        case "MET_UINT", "MET_ULONG":       return .uint32
        case "MET_LONG_LONG":               return .int64
        case "MET_ULONG_LONG":              return .uint64
        case "MET_FLOAT":                   return .float32
        case "MET_DOUBLE":                  return .float64
        default:
            throw MIQError.unsupportedFeature("MetaImage element type '\(value)' is not supported")
        }
    }

    private func parseMetaImageIntList(_ value: String, field: String) throws -> [Int] {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        let parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count, !parsed.isEmpty else {
            throw MIQError.malformedFile("MetaImage '\(field)' contains a non-integer value: '\(value)'")
        }
        return parsed
    }

    private func parseMetaImageFloatList(_ value: String) -> [Float]? {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        let parsed = parts.compactMap { Float($0) }
        return parsed.count == parts.count && !parsed.isEmpty ? parsed : nil
    }
}
