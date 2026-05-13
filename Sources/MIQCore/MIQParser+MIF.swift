import Foundation

extension MIQParser {
    private struct MifHeader {
        let dim: [Int]
        let vox: [Float]
        let layout: [MIFLayoutComponent]
        let datatype: MIQDatatype
        let littleEndian: Bool
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

        let (datatype, littleEndian) = try parseMifDatatype(datatypeString)
        let (dataFile, dataOffset) = try parseMifFileSpec(fileString)

        let scalingValues = keyValues["scaling"]?.last.flatMap { try? parseMifFloatList($0) }
        let offset = scalingValues?[safe: 0] ?? 0
        let scale = scalingValues?[safe: 1] ?? 1

        return MifHeader(
            dim: dim,
            vox: vox,
            layout: layout,
            datatype: datatype,
            littleEndian: littleEndian,
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
        let baseElementIndex: Int
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
            orientationFrame: OrientationFrame.fromMifLabel(orientationLabel)
        )

        return MifImageDescriptor(
            header: miqHeader,
            strides4: strides4,
            baseElementIndex: 0
        )
    }

    private func buildMifImage(data: Data, dataOffset: Int, header: MifHeader) throws -> MIQImage {
        let elementCount = header.dim.reduce(1, *)
        let bytesPerVoxel = header.datatype.bytesPerVoxel
        let payloadBytes = elementCount * bytesPerVoxel

        guard elementCount > 0, payloadBytes > 0 else {
            throw MIQError.invalidDimensions
        }
        guard dataOffset >= 0, data.count >= dataOffset + payloadBytes else {
            throw MIQError.truncatedData
        }

        let descriptor = try buildMifMIQHeader(dataOffset: dataOffset, header: header)

        return MIQImage(
            header: descriptor.header,
            storage: data,
            payloadOffset: dataOffset,
            payloadBaseElementIndex: descriptor.baseElementIndex,
            payloadElementStrides: descriptor.strides4
        )
    }

    // MARK: - Field parsers

    private func parseMifDatatype(_ value: String) throws -> (MIQDatatype, Bool) {
        let lowered = value.lowercased()
        let isLittleEndian = !lowered.hasSuffix("be")

        if lowered.hasPrefix("uint8") { return (.uint8, true) }
        if lowered.hasPrefix("int8") { return (.int8, true) }
        if lowered.hasPrefix("uint16") { return (.uint16, isLittleEndian) }
        if lowered.hasPrefix("int16") { return (.int16, isLittleEndian) }
        if lowered.hasPrefix("uint32") { return (.uint32, isLittleEndian) }
        if lowered.hasPrefix("int32") { return (.int32, isLittleEndian) }
        if lowered.hasPrefix("float32") { return (.float32, isLittleEndian) }
        if lowered.hasPrefix("float64") { return (.float64, isLittleEndian) }

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
