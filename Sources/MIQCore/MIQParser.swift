import Foundation

public struct MIQParser {
    public init() {}

    public func parse(url: URL) throws -> MIQImage {
        let (data, kind) = try loadAndDecompress(url: url)
        return try parseImage(data: data, kind: kind)
    }

    public func parseHeader(url: URL) throws -> MIQHeader {
        let (data, kind) = try loadAndDecompress(url: url)
        return try parseHeader(data: data, kind: kind)
    }

    // MARK: - Internal

    private func loadAndDecompress(url: URL) throws -> (Data, MIQFileKind) {
        guard let kind = MIQFileKind(url: url) else {
            throw MIQError.unsupportedFileFormat
        }
        let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        let data = kind.isCompressed ? try decompress(raw) : raw
        return (data, kind)
    }

    private func decompress(_ raw: Data) throws -> Data {
        guard MIQBinaryReader.isLikelyGzip(raw) else {
            throw MIQError.malformedFile("file extension claims gzip but the gzip magic bytes are missing")
        }
        return try MIQBinaryReader.gunzip(raw)
    }

    private func parseImage(data: Data, kind: MIQFileKind) throws -> MIQImage {
        switch kind {
        case .nii, .niiGz:
            return try parseNifti(data)
        case .mgh, .mgz:
            return try parseMgh(data)
        case .mif, .mifGz:
            return try parseMif(data)
        case .nrrd:
            return try parseNrrd(data)
        }
    }

    private func parseHeader(data: Data, kind: MIQFileKind) throws -> MIQHeader {
        switch kind {
        case .nii, .niiGz:
            return try parseNiftiHeader(from: data)
        case .mgh, .mgz:
            return try parseMghHeader(from: data)
        case .mif, .mifGz:
            return try parseMifHeaderOnly(from: data)
        case .nrrd:
            return try parseNrrdHeaderOnly(from: data)
        }
    }
}
