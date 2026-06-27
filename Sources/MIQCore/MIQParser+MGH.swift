import Foundation

extension MIQParser {
    private enum MghType: Int32 {
        case uchar = 0
        case int = 1
        case float = 3
        case short = 4

        var datatype: MIQDatatype {
            switch self {
            case .uchar: return .uint8
            case .int: return .int32
            case .float: return .float32
            case .short: return .int16
            }
        }
    }

    func parseMgh(_ data: Data) throws -> MIQImage {
        let header = try parseMghHeader(from: data)

        let voxelCount = header.width * header.height * header.depth * max(1, header.volumes)
        let payloadBytes = voxelCount * header.datatype.bytesPerVoxel
        guard payloadBytes > 0 else {
            throw MIQError.invalidDimensions
        }
        guard data.count >= header.voxOffset + payloadBytes else {
            throw MIQError.truncatedData
        }

        return MIQImage(header: header, storage: data, payloadOffset: header.voxOffset)
    }

    func parseMghHeader(from data: Data) throws -> MIQHeader {
        let mghHeaderSize = 284
        guard data.count >= mghHeaderSize else {
            throw MIQError.truncatedData
        }

        let version = MIQBinaryReader.int32(data, 0, littleEndian: false)
        guard version == 1 else {
            throw MIQError.unsupportedFormatVersion(version)
        }

        let width = Int(MIQBinaryReader.int32(data, 4, littleEndian: false))
        let height = Int(MIQBinaryReader.int32(data, 8, littleEndian: false))
        let depth = Int(MIQBinaryReader.int32(data, 12, littleEndian: false))
        let frames = Int(MIQBinaryReader.int32(data, 16, littleEndian: false))
        let typeRaw = MIQBinaryReader.int32(data, 20, littleEndian: false)

        guard width > 0, height > 0, depth > 0, frames > 0 else {
            throw MIQError.invalidDimensions
        }

        guard let mghType = MghType(rawValue: typeRaw) else {
            throw MIQError.unsupportedDatatype(typeRaw)
        }

        try validateDimensionExtent([width, height, depth, frames], bytesPerVoxel: mghType.datatype.bytesPerVoxel)

        let goodRAS = MIQBinaryReader.int16(data, 28, littleEndian: false)
        let pixdim: [Float]
        let srowX: [Float]
        let srowY: [Float]
        let srowZ: [Float]
        let sformCode: Int

        if goodRAS != 0 {
            let sx = max(1e-6, abs(MIQBinaryReader.float32(data, 30, littleEndian: false)))
            let sy = max(1e-6, abs(MIQBinaryReader.float32(data, 34, littleEndian: false)))
            let sz = max(1e-6, abs(MIQBinaryReader.float32(data, 38, littleEndian: false)))
            pixdim = [1.0, sx, sy, sz]

            let xr = MIQBinaryReader.float32(data, 42, littleEndian: false)
            let xa = MIQBinaryReader.float32(data, 46, littleEndian: false)
            let xs = MIQBinaryReader.float32(data, 50, littleEndian: false)
            let yr = MIQBinaryReader.float32(data, 54, littleEndian: false)
            let ya = MIQBinaryReader.float32(data, 58, littleEndian: false)
            let ys = MIQBinaryReader.float32(data, 62, littleEndian: false)
            let zr = MIQBinaryReader.float32(data, 66, littleEndian: false)
            let za = MIQBinaryReader.float32(data, 70, littleEndian: false)
            let zs = MIQBinaryReader.float32(data, 74, littleEndian: false)

            srowX = [xr, yr, zr, 0]
            srowY = [xa, ya, za, 0]
            srowZ = [xs, ys, zs, 0]
            sformCode = 1
        } else {
            pixdim = [1.0, 1.0, 1.0, 1.0]
            srowX = [1, 0, 0, 0]
            srowY = [0, 1, 0, 0]
            srowZ = [0, 0, 1, 0]
            sformCode = 0
        }

        let orientationFrame: OrientationFrame? = sformCode > 0
            ? OrientationFrame.from(srowX: srowX, srowY: srowY, srowZ: srowZ, source: .mghDirectionCosines)
            : nil

        return MIQHeader(
            littleEndian: false,
            dimensions: [width, height, depth, frames],
            pixdim: pixdim,
            datatype: mghType.datatype,
            voxOffset: mghHeaderSize,
            sclSlope: 0,
            sclInter: 0,
            qformCode: 0,
            sformCode: sformCode,
            srowX: srowX,
            srowY: srowY,
            srowZ: srowZ,
            orientationFrame: orientationFrame
        )
    }
}
