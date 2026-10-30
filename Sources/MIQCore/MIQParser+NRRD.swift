import Foundation

extension MIQParser {

    private enum NrrdEncoding { case raw, gzip }

    private struct NrrdParsedHeader {
        let sizes: [Int]
        let datatype: MIQDatatype
        let littleEndian: Bool
        let encoding: NrrdEncoding
        // Per-axis direction vectors in NRRD space; nil entry = non-spatial ("none")
        let spaceDirections: [[Float]?]?
        let spaceOrigin: [Float]?
        // Multipliers to convert NRRD (x,y,z) components to RAS (R,A,S);
        // nil when `space` is absent or not anatomical (scanner-xyz, 3D-…-handed)
        let toRasSigns: (rx: Float, ry: Float, rz: Float)?
        // Fallback voxel spacings when spaceDirections is absent
        let spacings: [Float]?
        /// The `content:` field.
        let content: String?
    }

    // MARK: - Public entry points

    func parseNrrd(_ data: Data) throws -> MIQImage {
        let (nrrd, storage, payloadOffset) = try loadNrrd(data: data)
        return try buildNrrdImage(nrrd: nrrd, storage: storage, payloadOffset: payloadOffset)
    }

    // MARK: - Loading

    private func loadNrrd(data: Data) throws -> (NrrdParsedHeader, Data, Int) {
        let (headerText, payloadIndex) = try splitNrrdHeader(data: data)
        let lines = headerText.split(whereSeparator: { $0.isNewline }).map(String.init)

        guard let first = lines.first, first.hasPrefix("NRRD000") else {
            throw MIQError.malformedFile("NRRD magic line not found; file does not appear to be NRRD format")
        }

        let fields = parseNrrdFields(lines: lines)
        let nrrd = try buildNrrdParsedHeader(fields: fields)

        let storage: Data
        let payloadOffset: Int
        switch nrrd.encoding {
        case .raw:
            storage = data
            payloadOffset = data.distance(from: data.startIndex, to: payloadIndex)
        case .gzip:
            let compressed = data[payloadIndex...]
            guard MIQBinaryReader.isLikelyGzip(compressed) else {
                throw MIQError.malformedFile("NRRD encoding is gzip but gzip magic bytes are missing in payload")
            }
            storage = try MIQBinaryReader.gunzip(compressed)
            payloadOffset = 0
        }

        return (nrrd, storage, payloadOffset)
    }

    private func splitNrrdHeader(data: Data) throws -> (String, Data.Index) {
        guard let separator = firstBlankLine(in: data) else {
            throw MIQError.malformedFile(
                "NRRD header is missing the blank-line separator; detached headers (.nhdr) are not supported"
            )
        }
        return (String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self), separator.upperBound)
    }

    /// The header ends at the *earliest* blank line (`\n\n` or `\n\r\n`). Walking
    /// newline to newline stops right there, so the payload is never scanned: a
    /// whole-file search pages in an mmap'd raw payload, and lets payload bytes that
    /// spell a blank line (`0D 0A 0D 0A`) win over the real separator. For a CRLF
    /// header the match starts one byte into `\r\n\r\n`, leaving a trailing `\r` on
    /// the header text, which the `isNewline` line split already drops.
    private func firstBlankLine(in data: Data) -> Range<Data.Index>? {
        let lf: UInt8 = 0x0A
        let cr: UInt8 = 0x0D
        var searchStart = data.startIndex
        while let newline = data[searchStart...].firstIndex(of: lf) {
            let next = newline + 1
            if next < data.endIndex, data[next] == lf {
                return newline..<(next + 1)
            }
            if next + 1 < data.endIndex, data[next] == cr, data[next + 1] == lf {
                return newline..<(next + 2)
            }
            searchStart = next
        }
        return nil
    }

    // MARK: - Thumbnail gate

    /// How many leading bytes `nrrdHasRawPayload(at:)` reads. Real headers are a
    /// few hundred bytes; one longer than this counts as not raw, the
    /// conservative answer (the thumbnail is declined rather than a gunzip paid).
    static let nrrdHeaderProbeBytes = 64 * 1024

    /// Whether a self-contained NRRD stores its payload raw, judged from the
    /// header alone. The `.nrrd` extension doesn't say: `encoding:` does, and a
    /// gzip payload must be inflated in full. Lets the thumbnail extension treat a
    /// local raw NRRD like an uncompressed MIF (memory-mapped, so size costs
    /// nothing). Any failure (unreadable file, no blank line within the probe, no
    /// magic, a detached header) answers `false`.
    public static func nrrdHasRawPayload(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: nrrdHeaderProbeBytes) else { return false }
        return nrrdHasRawPayload(prefix: prefix)
    }

    static func nrrdHasRawPayload(prefix: Data) -> Bool {
        let parser = MIQParser()
        guard let split = try? parser.splitNrrdHeader(data: prefix) else { return false }
        let lines = split.0.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.first?.hasPrefix("NRRD000") == true else { return false }
        let fields = parser.parseNrrdFields(lines: lines)
        guard fields["data file"] == nil, fields["datafile"] == nil else { return false }
        return (fields["encoding"] ?? "raw").lowercased() == "raw"
    }

    // MARK: - Header field parsing

    private func parseNrrdFields(lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix("#") else { continue }
            // Skip NRRD custom key-value pairs (key:=value); only parse standard fields (key: value)
            guard let colonIdx = line.firstIndex(of: ":"),
                  line.index(after: colonIdx) < line.endIndex,
                  line[line.index(after: colonIdx)] != "=" else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    private func buildNrrdParsedHeader(fields: [String: String]) throws -> NrrdParsedHeader {
        // Reject detached headers early
        if let dataFile = fields["data file"] ?? fields["datafile"] {
            throw MIQError.unsupportedFeature(
                "NRRD detached header (data file: \(dataFile)) is not supported; use a self-contained .nrrd file"
            )
        }

        // Encoding
        let encodingStr = (fields["encoding"] ?? "raw").lowercased()
        let encoding: NrrdEncoding
        switch encodingStr {
        case "raw":
            encoding = .raw
        case "gzip", "gz":
            encoding = .gzip
        case "ascii", "text", "txt":
            throw MIQError.unsupportedFeature(
                "NRRD ASCII encoding is not supported; re-save with encoding: raw or encoding: gzip"
            )
        case "hex":
            throw MIQError.unsupportedFeature(
                "NRRD hex encoding is not supported; re-save with encoding: raw or encoding: gzip"
            )
        case "bzip2", "bz2":
            throw MIQError.unsupportedFeature(
                "NRRD bzip2 encoding is not supported; re-save with encoding: raw or encoding: gzip"
            )
        default:
            throw MIQError.malformedFile("Unknown NRRD encoding '\(encodingStr)'")
        }

        guard let sizesStr = fields["sizes"] else {
            throw MIQError.malformedFile("NRRD header is missing required field 'sizes'")
        }
        let sizes = try parseNrrdIntList(sizesStr, field: "sizes")
        guard !sizes.isEmpty, sizes.allSatisfy({ $0 > 0 }) else {
            throw MIQError.invalidDimensions
        }

        guard let typeStr = fields["type"] else {
            throw MIQError.malformedFile("NRRD header is missing required field 'type'")
        }
        let datatype = try parseNrrdDatatype(typeStr)
        try validateDimensionExtent(sizes, bytesPerVoxel: datatype.bytesPerVoxel)

        let endianStr = (fields["endian"] ?? "little").lowercased()
        let littleEndian = endianStr != "big"

        let toRasSigns = nrrdSpaceToRasSigns(fields["space"]?.lowercased())

        let spaceDirections = fields["space directions"].map {
            parseNrrdSpaceDirections($0, axisCount: sizes.count)
        }
        let spaceOrigin = fields["space origin"].flatMap { parseNrrdVector($0) }
        let spacings = fields["spacings"].flatMap { parseNrrdSpacingList($0) }

        return NrrdParsedHeader(
            sizes: sizes,
            datatype: datatype,
            littleEndian: littleEndian,
            encoding: encoding,
            spaceDirections: spaceDirections,
            spaceOrigin: spaceOrigin,
            toRasSigns: toRasSigns,
            spacings: spacings,
            content: fields["content"]
        )
    }

    // MARK: - Image construction

    private struct NrrdImageDescriptor {
        let header: MIQHeader
        let strides: [Int]?
    }

    private func buildNrrdMIQHeader(nrrd: NrrdParsedHeader, payloadOffset: Int) throws -> NrrdImageDescriptor {
        let (spatialAxes, volumeAxis) = try nrrdAxisLayout(nrrd: nrrd)

        let sx = nrrd.sizes[spatialAxes[0]]
        let sy = nrrd.sizes[spatialAxes[1]]
        let sz = nrrd.sizes[spatialAxes[2]]
        let nVols = volumeAxis.map { nrrd.sizes[$0] } ?? 1

        // Raw element strides (each axis varies faster than the next)
        var rawStrides = [Int](repeating: 0, count: nrrd.sizes.count)
        var stride = 1
        for i in 0..<nrrd.sizes.count {
            rawStrides[i] = stride
            stride *= nrrd.sizes[i]
        }

        let xStride = rawStrides[spatialAxes[0]]
        let yStride = rawStrides[spatialAxes[1]]
        let zStride = rawStrides[spatialAxes[2]]
        let tStride = volumeAxis.map { rawStrides[$0] } ?? (sx * sy * sz)

        // Only store custom strides when they differ from the default (x-fastest) layout
        let defaultStrides = [1, sx, sx * sy, sx * sy * sz]
        let computedStrides = [xStride, yStride, zStride, tStride]
        let customStrides: [Int]? = computedStrides == defaultStrides ? nil : computedStrides

        let (pixX, pixY, pixZ, srowX, srowY, srowZ, hasAffine) = nrrdAffine(nrrd: nrrd, spatialAxes: spatialAxes)

        let orientationFrame: OrientationFrame? = hasAffine
            ? OrientationFrame.from(srowX: srowX, srowY: srowY, srowZ: srowZ, source: .nrrdSpaceDirections)
            : nil

        // A non-spatial axis may come first (e.g. a DWI list axis); the file's index
        // then leads with it.
        let indexAxes = FileIndexAxes(
            fileAxis: spatialAxes + [volumeAxis ?? 3],
            reversed: [false, false, false, false]
        )

        let header = MIQHeader(
            littleEndian: nrrd.littleEndian,
            dimensions: [sx, sy, sz, nVols],
            pixdim: [1.0, pixX, pixY, pixZ],
            datatype: nrrd.datatype,
            voxOffset: payloadOffset,
            sclSlope: 1.0,
            sclInter: 0.0,
            qformCode: 0,
            sformCode: orientationFrame != nil ? 1 : 0,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            formatLabel: nrrd.encoding == .gzip ? "Compressed NRRD" : nil,
            orientationFrame: orientationFrame,
            comment: nrrd.content.flatMap { Self.headerComment([$0]) },
            fileIndexAxes: indexAxes.isIdentity ? nil : indexAxes
        )

        return NrrdImageDescriptor(header: header, strides: customStrides)
    }

    private func buildNrrdImage(nrrd: NrrdParsedHeader, storage: Data, payloadOffset: Int) throws -> MIQImage {
        let totalElements = nrrd.sizes.reduce(1, *)
        let payloadBytes = totalElements * nrrd.datatype.bytesPerVoxel
        guard payloadBytes > 0 else { throw MIQError.invalidDimensions }
        // Subtraction form: `payloadOffset + payloadBytes` traps when the validated dims
        // product lands on `Int.max`. The offset is 0 for the gzip branch and the
        // header-split index (`<= count`) for raw, so the left side cannot go negative.
        guard storage.count - payloadOffset >= payloadBytes else { throw MIQError.truncatedData }

        let descriptor = try buildNrrdMIQHeader(nrrd: nrrd, payloadOffset: payloadOffset)

        return MIQImage(
            header: descriptor.header,
            storage: storage,
            payloadOffset: payloadOffset,
            payloadElementStrides: descriptor.strides
        )
    }

    // MARK: - Axis layout

    private func nrrdAxisLayout(nrrd: NrrdParsedHeader) throws -> ([Int], Int?) {
        let nAxes = nrrd.sizes.count

        guard let dirs = nrrd.spaceDirections else {
            // No space directions: assume first 3 axes are spatial
            guard nAxes >= 3 else { throw MIQError.invalidDimensions }
            guard nAxes <= 4 else {
                throw MIQError.unsupportedFeature(
                    "NRRD files with more than 4 dimensions are not supported"
                )
            }
            return ([0, 1, 2], nAxes == 4 ? 3 : nil)
        }

        var spatialAxes: [Int] = []
        var nonSpatialAxes: [Int] = []
        for (i, dir) in dirs.enumerated() {
            if dir != nil { spatialAxes.append(i) } else { nonSpatialAxes.append(i) }
        }

        guard spatialAxes.count == 3 else {
            throw MIQError.unsupportedFeature(
                "NRRD file does not appear to be a previewable volume (found \(spatialAxes.count) spatial axes, expected 3)"
            )
        }
        guard nonSpatialAxes.count <= 1 else {
            throw MIQError.unsupportedFeature(
                "NRRD files with multiple non-spatial axes are not supported"
            )
        }

        return (spatialAxes, nonSpatialAxes.first)
    }

    // MARK: - Affine

    private func nrrdAffine(
        nrrd: NrrdParsedHeader,
        spatialAxes: [Int]
    ) -> (Float, Float, Float, [Float], [Float], [Float], Bool) {
        if let dirs = nrrd.spaceDirections {
            let v0 = dirs[spatialAxes[0]] ?? [1, 0, 0]
            let v1 = dirs[spatialAxes[1]] ?? [0, 1, 0]
            let v2 = dirs[spatialAxes[2]] ?? [0, 0, 1]

            let pixX = sqrt(v0[0]*v0[0] + v0[1]*v0[1] + v0[2]*v0[2])
            let pixY = sqrt(v1[0]*v1[0] + v1[1]*v1[1] + v1[2]*v1[2])
            let pixZ = sqrt(v2[0]*v2[0] + v2[1]*v2[1] + v2[2]*v2[2])

            // Directions without an anatomical space say nothing about which side
            // is which: keep the spacing, build no affine (resolver shows "?").
            guard let signs = nrrd.toRasSigns else {
                return (pixX, pixY, pixZ, [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], false)
            }
            let (rx, ry, rz) = (signs.rx, signs.ry, signs.rz)

            let ox = (nrrd.spaceOrigin?[safe: 0] ?? 0) * rx
            let oy = (nrrd.spaceOrigin?[safe: 1] ?? 0) * ry
            let oz = (nrrd.spaceOrigin?[safe: 2] ?? 0) * rz

            // srowX[i] = R component of storage axis i's world direction
            // srowY[i] = A component, srowZ[i] = S component
            let srowX: [Float] = [v0[0]*rx, v1[0]*rx, v2[0]*rx, ox]
            let srowY: [Float] = [v0[1]*ry, v1[1]*ry, v2[1]*ry, oy]
            let srowZ: [Float] = [v0[2]*rz, v1[2]*rz, v2[2]*rz, oz]

            return (pixX, pixY, pixZ, srowX, srowY, srowZ, true)
        }

        // Fallback: spacings only — no directions means no orientation, whatever
        // `space` says, so keep the spacing and build no affine (resolver shows "?").
        let pixX = abs(nrrd.spacings?[safe: spatialAxes[0]] ?? 1)
        let pixY = abs(nrrd.spacings?[safe: spatialAxes[1]] ?? 1)
        let pixZ = abs(nrrd.spacings?[safe: spatialAxes[2]] ?? 1)

        return (pixX, pixY, pixZ, [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], false)
    }

    private func nrrdSpaceToRasSigns(_ space: String?) -> (rx: Float, ry: Float, rz: Float)? {
        // The "-time" spaces (RAST, LPST, …) add a temporal world axis after the
        // three anatomical ones, which keep their meaning.
        guard var space else { return nil }
        if space.hasSuffix("-time") {
            space.removeLast(5)
        } else if space.count == 4, space.hasSuffix("t") {
            space.removeLast()
        }
        switch space {
        case "right-anterior-superior", "ras":           return (1,  1,  1)
        case "left-anterior-superior", "las":            return (-1, 1,  1)
        case "left-posterior-superior", "lps":           return (-1, -1, 1)
        case "right-posterior-superior", "rps":          return (1,  -1, 1)
        case "right-anterior-inferior", "rai":           return (1,  1,  -1)
        case "left-anterior-inferior", "lai":            return (-1, 1,  -1)
        case "left-posterior-inferior", "lpi":           return (-1, -1, -1)
        case "right-posterior-inferior", "rpi":          return (1,  -1, -1)
        default:                                          return nil
        }
    }

    // MARK: - Field value parsers

    private func parseNrrdDatatype(_ value: String) throws -> MIQDatatype {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "int8", "int8_t", "signed char":                                   return .int8
        case "uint8", "uint8_t", "uchar", "unsigned char":                      return .uint8
        case "int16", "int16_t", "short", "short int",
             "signed short", "signed short int":                                 return .int16
        case "uint16", "uint16_t", "ushort",
             "unsigned short", "unsigned short int":                             return .uint16
        case "int32", "int32_t", "int", "signed int":                           return .int32
        case "uint32", "uint32_t", "uint", "unsigned int":                      return .uint32
        case "float":                                                            return .float32
        case "double":                                                           return .float64
        case "int64", "int64_t", "longlong", "long long",
             "signed long long", "signed long long int":                        return .int64
        case "uint64", "uint64_t", "ulonglong",
             "unsigned long long", "unsigned long long int":                    return .uint64
        default:
            throw MIQError.malformedFile("Unrecognised NRRD type '\(value)'")
        }
    }

    private func parseNrrdIntList(_ value: String, field: String) throws -> [Int] {
        let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let parsed = parts.compactMap(Int.init)
        guard parsed.count == parts.count, !parsed.isEmpty else {
            throw MIQError.malformedFile("NRRD '\(field)' contains a non-integer value: '\(value)'")
        }
        return parsed
    }

    private func parseNrrdSpacingList(_ value: String) -> [Float]? {
        let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let parsed = parts.compactMap(Float.init)
        return parsed.count == parts.count && !parsed.isEmpty ? parsed : nil
    }

    /// Parses `space directions` into per-axis direction vectors; `nil` entries represent "none".
    private func parseNrrdSpaceDirections(_ value: String, axisCount: Int) -> [[Float]?] {
        var result: [[Float]?] = []
        var cursor = value[...]
        while result.count < axisCount {
            cursor = cursor.drop(while: { $0.isWhitespace })
            if cursor.isEmpty { break }
            if cursor.hasPrefix("none") {
                result.append(nil)
                cursor = cursor.dropFirst(4)
            } else if let group = parseParenthesisedFloats(cursor) {
                result.append(spatialDirection(group.components))
                cursor = group.remainder
            } else {
                cursor = cursor.drop(while: { !$0.isWhitespace })
            }
        }
        while result.count < axisCount { result.append(nil) }
        return result
    }

    /// The (x, y, z) direction of a spatial axis, or nil for a non-spatial one.
    /// A "-time" space writes 4-component vectors: a spatial axis has no time
    /// component, the time axis has nothing else.
    private func spatialDirection(_ components: [Float]) -> [Float]? {
        switch components.count {
        case 3: return components
        case 4 where components[3] == 0: return Array(components.prefix(3))
        default: return nil
        }
    }

    /// Parses a parenthesised vector like `(x, y, z)`.
    private func parseNrrdVector(_ value: String) -> [Float]? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let group = parseParenthesisedFloats(trimmed[...]) else { return nil }
        return group.components.count >= 3 ? Array(group.components.prefix(3)) : nil
    }

    /// Parses the comma-separated floats inside a leading parenthesised group like
    /// `(x, y, z)`. Returns the parsed components (no arity enforcement — callers
    /// apply their own count rule) plus the slice of `value` immediately after the
    /// closing `)`, or `nil` when `value` does not begin with a closed `(...)` group.
    private func parseParenthesisedFloats(_ value: Substring) -> (components: [Float], remainder: Substring)? {
        guard value.hasPrefix("("), let closeIdx = value.firstIndex(of: ")") else { return nil }
        let inner = value[value.index(after: value.startIndex)..<closeIdx]
        let components = inner.split(separator: ",")
            .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        return (components, value[value.index(after: closeIdx)...])
    }
}
