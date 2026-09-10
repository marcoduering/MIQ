import Foundation

extension MIQParser {
    private struct MifHeader {
        let dim: [Int]
        let vox: [Float]
        let layout: [MIFLayoutComponent]
        let datatype: MIQDatatype
        let littleEndian: Bool
        /// MRtrix `bit`: one voxel per bit on disk, expanded to one `uint8` per voxel at parse time.
        let bitPacked: Bool
        let dataFile: String
        let dataOffset: Int
        let scale: Float
        let offset: Float
    }

    func parseMif(_ data: Data) throws -> MIQImage {
        let (mifHeader, embeddedDataOffset) = try parseMifHeader(from: data)
        guard mifHeader.dataFile == "." else {
            throw MIQError.malformedFile("MIF references an external data file; only embedded payloads are supported")
        }
        let dataOffset = mifHeader.dataOffset > 0 ? mifHeader.dataOffset : embeddedDataOffset
        return try buildMifImage(data: data, dataOffset: dataOffset, header: mifHeader)
    }

    /// Header-only MIF parse — derives an MIQHeader without validating the payload.
    func parseMifHeaderOnly(from data: Data) throws -> MIQHeader {
        let (mifHeader, embeddedDataOffset) = try parseMifHeader(from: data)
        guard mifHeader.dataFile == "." else {
            throw MIQError.malformedFile("MIF references an external data file; only embedded payloads are supported")
        }
        let dataOffset = mifHeader.dataOffset > 0 ? mifHeader.dataOffset : embeddedDataOffset
        return try buildMifMIQHeader(dataOffset: dataOffset, header: mifHeader).header
    }

    // MARK: - Header lines

    private func parseMifHeader(from data: Data) throws -> (MifHeader, Int) {
        let (lines, embeddedDataOffset) = try parseMifHeaderLines(from: data)
        let mifHeader = try parseMifHeaderFields(lines: lines)
        return (mifHeader, embeddedDataOffset)
    }

    private func parseMifHeaderLines(from data: Data) throws -> ([String], Int) {
        // Match END only when preceded by a newline so values like "LEGEND" don't trigger a false hit.
        guard let markerRange = data.range(of: Data("\nEND".utf8)) else {
            throw MIQError.malformedFile("MIF header is missing the END marker")
        }

        var payloadStart = markerRange.upperBound
        if payloadStart < data.endIndex, data[payloadStart] == 0x0D {
            payloadStart += 1
        }
        if payloadStart < data.endIndex, data[payloadStart] == 0x0A {
            payloadStart += 1
        }

        // The leading newline belongs to the previous line; stop the header text there.
        let headerData = data[data.startIndex..<markerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        return (lines, payloadStart)
    }

    private func parseMifHeaderFields(lines: [String]) throws -> MifHeader {
        guard let first = lines.first, first.lowercased() == "mrtrix image" else {
            throw MIQError.malformedFile("MIF header does not start with 'mrtrix image'")
        }

        var keyValues: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let sep = line.firstIndex(of: ":") else {
                continue
            }

            let key = line[..<sep].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespacesAndNewlines)
            keyValues[key, default: []].append(String(value))
        }

        guard let dimString = keyValues["dim"]?.last,
              let voxString = keyValues["vox"]?.last,
              let layoutString = keyValues["layout"]?.last,
              let datatypeString = keyValues["datatype"]?.last,
              let fileString = keyValues["file"]?.last else {
            throw MIQError.malformedFile("MIF header is missing one or more required fields (dim, vox, layout, datatype, file)")
        }

        let dim = try parseMifIntList(dimString)
        let vox = try parseMifFloatList(voxString)
        let layout = try parseMifLayoutList(layoutString)
        guard dim.count == vox.count, dim.count == layout.count else {
            throw MIQError.invalidDimensions
        }
        guard dim.count >= 3, dim.count <= 4, dim.allSatisfy({ $0 > 0 }) else {
            throw MIQError.invalidDimensions
        }

        let spec = try parseMifDatatype(datatypeString)
        // `bytesPerVoxel` here is the *unpacked* size (1 for `bit`), which is what
        // bounds the buffer this parser hands downstream.
        try validateDimensionExtent(dim, bytesPerVoxel: spec.datatype.bytesPerVoxel)
        let (dataFile, dataOffset) = try parseMifFileSpec(fileString)

        let scalingValues = keyValues["scaling"]?.last.flatMap { try? parseMifFloatList($0) }
        // MIF spells the pair `offset,scale` — note the argument order. Normalised
        // like NIfTI's: the field is free text, so `Float("nan")` parses.
        let (scale, offset) = normalizedScaling(
            slope: scalingValues?[safe: 1] ?? 1,
            inter: scalingValues?[safe: 0] ?? 0
        )

        return MifHeader(
            dim: dim,
            vox: vox,
            layout: layout,
            datatype: spec.datatype,
            littleEndian: spec.littleEndian,
            bitPacked: spec.bitPacked,
            dataFile: dataFile,
            dataOffset: dataOffset,
            scale: scale,
            offset: offset
        )
    }

    // MARK: - Image construction

    private struct MifImageDescriptor {
        let header: MIQHeader
        let strides4: [Int]
    }

    private func buildMifMIQHeader(dataOffset: Int, header: MifHeader) throws -> MifImageDescriptor {
        let axisLayout = try MIFAxisLayout(dim: header.dim, layout: header.layout)
        let rawStrides = axisLayout.rawStrides

        // Sort the 3 spatial axes (0,1,2) by abs(layout) to get storage rank order.
        // This determines which axis varies fastest in memory → shown as logical x.
        // The time axis (index 3, if present) is excluded from permutation.
        let spatialAxes = [0, 1, 2].sorted { header.layout[$0].order < header.layout[$1].order }

        let dim0 = header.dim[spatialAxes[0]]
        let dim1 = header.dim[spatialAxes[1]]
        let dim2 = header.dim[spatialAxes[2]]
        let volumes = header.dim[safe: 3] ?? 1

        let pixX = abs(header.vox[safe: spatialAxes[0]] ?? 1)
        let pixY = abs(header.vox[safe: spatialAxes[1]] ?? 1)
        let pixZ = abs(header.vox[safe: spatialAxes[2]] ?? 1)

        // Render in storage traversal order: axis sign controls labels/orientation,
        // while sampling walks payload in increasing element index order.
        // This preserves "as stored" appearance for mirrored layouts (e.g. RAS vs LAS).
        let defaultVolStride = dim0 * dim1 * dim2
        let tStride = abs(rawStrides[safe: 3] ?? defaultVolStride)
        let strides4 = [
            abs(rawStrides[spatialAxes[0]]),
            abs(rawStrides[spatialAxes[1]]),
            abs(rawStrides[spatialAxes[2]]),
            tStride
        ]

        let orientationLabel = MIFAxisLayout.orientationLabel(spatialAxes: spatialAxes, layout: header.layout)

        let miqHeader = MIQHeader(
            littleEndian: header.littleEndian,
            dimensions: [dim0, dim1, dim2, volumes],
            pixdim: [1.0, pixX, pixY, pixZ],
            datatype: header.datatype,
            voxOffset: dataOffset,
            sclSlope: header.scale,
            sclInter: header.offset,
            qformCode: 0,
            sformCode: 0,
            srowX: [],
            srowY: [],
            srowZ: [],
            datatypeLabel: header.bitPacked ? "bit" : nil,
            orientationFrame: OrientationFrame.fromMifLabel(orientationLabel)
        )

        return MifImageDescriptor(
            header: miqHeader,
            strides4: strides4
        )
    }

    private func buildMifImage(data: Data, dataOffset: Int, header: MifHeader) throws -> MIQImage {
        let elementCount = header.dim.reduce(1, *)
        let bytesPerVoxel = header.datatype.bytesPerVoxel
        // A `bit` payload occupies ceil(n/8) bytes on disk, not one byte per voxel.
        // Written as division rather than `(elementCount + 7) / 8`: `validateDimensionExtent`
        // permits a dims product of exactly `Int.max`, where the `+ 7` would trap.
        let payloadBytes = header.bitPacked
            ? elementCount / 8 + (elementCount % 8 == 0 ? 0 : 1)
            : elementCount * bytesPerVoxel

        guard elementCount > 0, payloadBytes > 0 else {
            throw MIQError.invalidDimensions
        }
        // `dataOffset` comes from the free-text `file:` field, so it can be any
        // Int64 the file cares to spell out (`file: . 9223372036854775807`).
        // `validateDimensionExtent` bounds `payloadBytes` but not the offset, so
        // the sum needs a checked add — a plain `+` traps and crashes the extension.
        let (payloadEnd, overflow) = dataOffset.addingReportingOverflow(payloadBytes)
        guard dataOffset >= 0, !overflow, data.count >= payloadEnd else {
            throw MIQError.truncatedData
        }

        let descriptor = try buildMifMIQHeader(dataOffset: dataOffset, header: header)

        if header.bitPacked {
            // The unpacked buffer holds the payload alone, in the same element order,
            // so the layout-derived strides carry over unchanged and the offset is 0.
            // `descriptor.header.voxOffset` still reports the offset *in the file*.
            return MIQImage(
                header: descriptor.header,
                storage: unpackMifBits(data, offset: dataOffset, voxelCount: elementCount),
                payloadOffset: 0,
                payloadElementStrides: descriptor.strides4
            )
        }

        return MIQImage(
            header: descriptor.header,
            storage: data,
            payloadOffset: dataOffset,
            payloadElementStrides: descriptor.strides4
        )
    }

    /// Expands an MRtrix `bit` payload to one `uint8` (0 or 1) per voxel.
    ///
    /// Bits run MSB-first within each byte — voxel *i* is bit `0x80 >> (i % 8)` of byte
    /// `i / 8` — matching MRtrix3's `BITMASK (0x01U << 7)` in `core/fetch_store.cpp`.
    ///
    /// Every downstream reader (`prepareSlice`, `voxel()`, the segmentation scans) addresses
    /// voxels as `elementIndex * bytesPerVoxel`, so a sub-byte datatype has no place in that
    /// model. Expanding once here — rather than threading bit addressing through the hot
    /// decode loop for one rare datatype — is the deliberate exception to the payload-offset
    /// convention: this is the only MIF path that copies instead of slicing the mapped file in
    /// place. A mask costs 8× its packed size (a 120×120×78 example: 141 KB → 1.1 MB), which is
    /// immaterial next to the slice render it feeds, and `bit` only ever appears on masks.
    private func unpackMifBits(_ data: Data, offset: Int, voxelCount: Int) -> Data {
        var unpacked = Data(count: voxelCount)
        unpacked.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                var voxel = 0
                var byteIndex = offset
                while voxel + 8 <= voxelCount {
                    let packed = src.loadUnaligned(fromByteOffset: byteIndex, as: UInt8.self)
                    dst[voxel] = (packed >> 7) & 1
                    dst[voxel + 1] = (packed >> 6) & 1
                    dst[voxel + 2] = (packed >> 5) & 1
                    dst[voxel + 3] = (packed >> 4) & 1
                    dst[voxel + 4] = (packed >> 3) & 1
                    dst[voxel + 5] = (packed >> 2) & 1
                    dst[voxel + 6] = (packed >> 1) & 1
                    dst[voxel + 7] = packed & 1
                    voxel += 8
                    byteIndex += 1
                }
                if voxel < voxelCount {
                    let packed = src.loadUnaligned(fromByteOffset: byteIndex, as: UInt8.self)
                    var bit = 7
                    while voxel < voxelCount {
                        dst[voxel] = (packed >> UInt8(bit)) & 1
                        voxel += 1
                        bit -= 1
                    }
                }
            }
        }
        return unpacked
    }

    // MARK: - Field parsers

    private func parseMifDatatype(
        _ value: String
    ) throws -> (datatype: MIQDatatype, littleEndian: Bool, bitPacked: Bool) {
        let lowered = value.lowercased()
        let isLittleEndian = !lowered.hasSuffix("be")

        // MRtrix writes a bare "Bit" — no byte order to speak of — so this is an exact
        // match, not the `hasPrefix` the sized types use to absorb their LE/BE suffix.
        // Presented as `uint8` because the payload is expanded to one byte per voxel
        // (see `unpackMifBits`).
        if lowered == "bit" { return (.uint8, true, true) }
        if lowered.hasPrefix("uint8") { return (.uint8, true, false) }
        if lowered.hasPrefix("int8") { return (.int8, true, false) }
        if lowered.hasPrefix("uint16") { return (.uint16, isLittleEndian, false) }
        if lowered.hasPrefix("int16") { return (.int16, isLittleEndian, false) }
        if lowered.hasPrefix("uint32") { return (.uint32, isLittleEndian, false) }
        if lowered.hasPrefix("int32") { return (.int32, isLittleEndian, false) }
        if lowered.hasPrefix("float32") { return (.float32, isLittleEndian, false) }
        if lowered.hasPrefix("float64") { return (.float64, isLittleEndian, false) }

        throw MIQError.malformedFile("unrecognised MIF datatype '\(value)'")
    }

    private func parseMifFileSpec(_ value: String) throws -> (String, Int) {
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        guard let filePart = parts.first else {
            throw MIQError.malformedFile("MIF 'file' field is empty")
        }

        let file = String(filePart)
        let offset = Int(parts[safe: 1] ?? "0") ?? 0
        return (file, max(0, offset))
    }

    private func parseMifIntList(_ value: String) throws -> [Int] {
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parsed = items.compactMap(Int.init)
        guard parsed.count == items.count, !parsed.isEmpty else {
            throw MIQError.malformedFile("MIF integer list is empty or contains a non-integer value: '\(value)'")
        }
        return parsed
    }

    private func parseMifLayoutList(_ value: String) throws -> [MIFLayoutComponent] {
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !items.isEmpty else {
            throw MIQError.malformedFile("MIF layout list is empty")
        }

        var parsed: [MIFLayoutComponent] = []
        parsed.reserveCapacity(items.count)

        for item in items {
            guard !item.isEmpty else {
                throw MIQError.malformedFile("MIF layout list contains an empty entry")
            }

            var reversed = false
            var digits = item
            if let first = item.first {
                if first == "-" {
                    reversed = true
                    digits = String(item.dropFirst())
                } else if first == "+" {
                    digits = String(item.dropFirst())
                }
            }

            guard let order = Int(digits), order >= 0 else {
                throw MIQError.malformedFile("MIF layout entry '\(item)' is not a signed non-negative integer")
            }
            parsed.append(MIFLayoutComponent(order: order, reversed: reversed))
        }

        return parsed
    }

    private func parseMifFloatList(_ value: String) throws -> [Float] {
        let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let parsed = items.compactMap(Float.init)
        guard parsed.count == items.count, !parsed.isEmpty else {
            throw MIQError.malformedFile("MIF float list is empty or contains a non-numeric value: '\(value)'")
        }
        return parsed
    }
}
