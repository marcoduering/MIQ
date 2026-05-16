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

    /// Generous prefix that comfortably contains any NIfTI fixed header (≤ 540 B)
    /// plus typical extensions — enough to compute the payload budget cheaply.
    private static let headerProbeBytes = 64 * 1024

    private func loadAndDecompress(url: URL) throws -> (Data, MIQFileKind) {
        guard let kind = MIQFileKind(url: url) else {
            throw MIQError.unsupportedFileFormat
        }
        let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard kind.isCompressed else {
            return (raw, kind)
        }
        guard MIQBinaryReader.isLikelyGzip(raw) else {
            throw MIQError.malformedFile("file extension claims gzip but the gzip magic bytes are missing")
        }

        // Decompress only the prefix the preview actually reads, when the layout
        // makes that a bounded prefix. Otherwise fall back to full decompression.
        if let budget = niftiVolumeZeroBudget(raw: raw, kind: kind) {
            return (try MIQBinaryReader.gunzip(raw, maxOutputBytes: budget), kind)
        }
        return (try MIQBinaryReader.gunzip(raw), kind)
    }

    /// Byte budget covering everything up to and including volume 0 of a
    /// canonical NIfTI payload (`vox_offset + W·H·D·bytesPerVoxel`).
    ///
    /// `nil` (→ full decompression) for every other compressed kind:
    /// - MGH: `parseMgh` guards the *full* payload, so a truncated buffer would
    ///   be rejected.
    /// - MIF: arbitrary `payloadElementStrides` — a spatial or temporal axis can
    ///   be scattered through the entire file, so volume 0 is not a prefix.
    ///
    /// A Quick Look preview only ever reads volume 0 (the model hard-codes
    /// volumeIndex 0; scrolling moves only x/y/z), and NIfTI stores time as the
    /// outermost (slowest) axis with no strides, so this budget is exactly
    /// sufficient and never short. For 3D NIfTI it equals the full payload.
    private func niftiVolumeZeroBudget(raw: Data, kind: MIQFileKind) -> Int? {
        guard kind == .niiGz,
              let probe = try? MIQBinaryReader.gunzip(raw, maxOutputBytes: Self.headerProbeBytes),
              let header = try? parseNiftiHeader(from: probe) else {
            return nil
        }
        let volumeElements = header.width * header.height * header.depth
        let payloadBytes = volumeElements * header.datatype.bytesPerVoxel
        guard volumeElements > 0, payloadBytes > 0 else { return nil }
        let budget = header.voxOffset + payloadBytes
        return budget > 0 ? budget : nil
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
