import Foundation

extension MIQParser {
    func parseNifti(_ data: Data) throws -> MIQImage {
        let header = try parseNiftiHeader(from: data)
        guard data.count >= header.voxOffset else {
            throw MIQError.truncatedData
        }
        return MIQImage(header: header, storage: data, payloadOffset: header.voxOffset)
    }

    func parseNiftiHeader(from data: Data) throws -> MIQHeader {
        guard data.count >= 4 else { throw MIQError.truncatedData }

        let headerSizeLE = MIQBinaryReader.int32(data, 0, littleEndian: true)
        let headerSizeBE = MIQBinaryReader.int32(data, 0, littleEndian: false)

        if headerSizeLE == 348 || headerSizeBE == 348 {
            return try parseNifti1Header(from: data, littleEndian: headerSizeLE == 348)
        } else if headerSizeLE == 540 || headerSizeBE == 540 {
            return try parseNifti2Header(from: data, littleEndian: headerSizeLE == 540)
        } else {
            throw MIQError.invalidHeaderSize(headerSizeLE)
        }
    }

    // MARK: - NIfTI-1 (348-byte header)

    private func parseNifti1Header(from data: Data, littleEndian: Bool) throws -> MIQHeader {
        guard data.count >= 348 else { throw MIQError.truncatedData }

        let dim = MIQBinaryReader.int16Array(data, 40, count: 8, littleEndian: littleEndian)
        let dimensions = try parseDimensions(dim.map { Int($0) })

        let datatype = try readAndValidateDatatype(data: data, at: 70, bitpixAt: 72, littleEndian: littleEndian)

        let pixdim = MIQBinaryReader.float32Array(data, 76, count: 8, littleEndian: littleEndian)
        let voxOffset = Int(MIQBinaryReader.float32(data, 108, littleEndian: littleEndian))
        let sclSlope = MIQBinaryReader.float32(data, 112, littleEndian: littleEndian)
        let sclInter = MIQBinaryReader.float32(data, 116, littleEndian: littleEndian)
        let qformCode = Int(MIQBinaryReader.int16(data, 252, littleEndian: littleEndian))
        let sformCode = Int(MIQBinaryReader.int16(data, 254, littleEndian: littleEndian))
        let quaternB = MIQBinaryReader.float32(data, 256, littleEndian: littleEndian)
        let quaternC = MIQBinaryReader.float32(data, 260, littleEndian: littleEndian)
        let quaternD = MIQBinaryReader.float32(data, 264, littleEndian: littleEndian)
        let srowX = MIQBinaryReader.float32Array(data, 280, count: 4, littleEndian: littleEndian)
        let srowY = MIQBinaryReader.float32Array(data, 296, count: 4, littleEndian: littleEndian)
        let srowZ = MIQBinaryReader.float32Array(data, 312, count: 4, littleEndian: littleEndian)

        let orientationFrame = niftiOrientationFrame(
            sform: SformFields(code: sformCode, rowX: srowX, rowY: srowY, rowZ: srowZ),
            qform: QformFields(code: qformCode, quaternB: quaternB, quaternC: quaternC, quaternD: quaternD, qfac: pixdim[safe: 0] ?? 1)
        )

        return MIQHeader(
            littleEndian: littleEndian,
            dimensions: dimensions,
            pixdim: Array(pixdim.prefix(4)),
            datatype: datatype,
            voxOffset: max(352, voxOffset),
            sclSlope: sclSlope,
            sclInter: sclInter,
            qformCode: qformCode,
            sformCode: sformCode,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            orientationFrame: orientationFrame
        )
    }

    // MARK: - NIfTI-2 (540-byte header)
    // Field types are widened relative to NIfTI-1: dim→int64, pixdim→float64,
    // vox_offset→int64, scl_slope/inter→float64, srow→float64, form_codes→int32.

    private func parseNifti2Header(from data: Data, littleEndian: Bool) throws -> MIQHeader {
        guard data.count >= 540 else { throw MIQError.truncatedData }

        let dim = MIQBinaryReader.int64Array(data, 16, count: 8, littleEndian: littleEndian)
        let dimensions = try parseDimensions(dim.map { Int($0) })

        let datatype = try readAndValidateDatatype(data: data, at: 12, bitpixAt: 14, littleEndian: littleEndian)

        let pixdim = MIQBinaryReader.float64Array(data, 104, count: 4, littleEndian: littleEndian).map { Float($0) }
        let voxOffset = Int(MIQBinaryReader.int64(data, 168, littleEndian: littleEndian))
        let sclSlope = Float(MIQBinaryReader.float64(data, 176, littleEndian: littleEndian))
        let sclInter = Float(MIQBinaryReader.float64(data, 184, littleEndian: littleEndian))
        let qformCode = Int(MIQBinaryReader.int32(data, 344, littleEndian: littleEndian))
        let sformCode = Int(MIQBinaryReader.int32(data, 348, littleEndian: littleEndian))
        let quaternB = Float(MIQBinaryReader.float64(data, 352, littleEndian: littleEndian))
        let quaternC = Float(MIQBinaryReader.float64(data, 360, littleEndian: littleEndian))
        let quaternD = Float(MIQBinaryReader.float64(data, 368, littleEndian: littleEndian))
        let srowX = MIQBinaryReader.float64Array(data, 400, count: 4, littleEndian: littleEndian).map { Float($0) }
        let srowY = MIQBinaryReader.float64Array(data, 432, count: 4, littleEndian: littleEndian).map { Float($0) }
        let srowZ = MIQBinaryReader.float64Array(data, 464, count: 4, littleEndian: littleEndian).map { Float($0) }

        let orientationFrame = niftiOrientationFrame(
            sform: SformFields(code: sformCode, rowX: srowX, rowY: srowY, rowZ: srowZ),
            qform: QformFields(code: qformCode, quaternB: quaternB, quaternC: quaternC, quaternD: quaternD, qfac: pixdim[safe: 0] ?? 1)
        )

        return MIQHeader(
            littleEndian: littleEndian,
            dimensions: dimensions,
            pixdim: Array(pixdim),
            datatype: datatype,
            voxOffset: max(544, voxOffset),
            sclSlope: sclSlope,
            sclInter: sclInter,
            qformCode: qformCode,
            sformCode: sformCode,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            orientationFrame: orientationFrame
        )
    }

    // MARK: - Shared helpers

    private struct SformFields {
        let code: Int
        let rowX: [Float]
        let rowY: [Float]
        let rowZ: [Float]
    }

    private struct QformFields {
        let code: Int
        let quaternB: Float
        let quaternC: Float
        let quaternD: Float
        let qfac: Float
    }

    /// Resolves the anatomical orientation frame per NIfTI-1 spec rules: prefer
    /// sform when present and non-degenerate; otherwise fall back to qform; otherwise
    /// `nil`. Sform wins when both are valid because the spec treats sform as the
    /// "newer" / preferred transform.
    private func niftiOrientationFrame(sform: SformFields, qform: QformFields) -> OrientationFrame? {
        if sform.code > 0,
           let frame = OrientationFrame.from(srowX: sform.rowX, srowY: sform.rowY, srowZ: sform.rowZ, source: .sform) {
            return frame
        }
        if qform.code > 0,
           let frame = OrientationFrame.fromQuaternion(b: qform.quaternB, c: qform.quaternC, d: qform.quaternD, qfac: qform.qfac) {
            return frame
        }
        return nil
    }

    private func readAndValidateDatatype(data: Data, at datatypeOffset: Int, bitpixAt bitpixOffset: Int, littleEndian: Bool) throws -> MIQDatatype {
        let raw = MIQBinaryReader.int16(data, datatypeOffset, littleEndian: littleEndian)
        guard let datatype = MIQDatatype(rawValue: raw) else { throw MIQError.unsupportedDatatype(Int32(raw)) }
        let bitpix = Int(MIQBinaryReader.int16(data, bitpixOffset, littleEndian: littleEndian))
        if bitpix != datatype.bytesPerVoxel * 8 { throw MIQError.unsupportedDatatype(Int32(raw)) }
        return datatype
    }

    private func parseDimensions(_ dim: [Int]) throws -> [Int] {
        let ndim = dim[0]
        guard ndim >= 1 else { throw MIQError.invalidDimensions }
        var dimensions: [Int] = []
        for idx in 1...max(3, min(7, ndim)) {
            dimensions.append(max(1, dim[idx]))
        }
        while dimensions.count < 4 { dimensions.append(1) }
        return dimensions
    }
}
