import Foundation

public struct MIQParser {
    public init() { /* value type, no stored state */ }

    /// - Parameter fullyDecompress: When `true`, bypass the volume-0 budget cap
    ///   for `.nii.gz` and decompress the entire stream. The default (`false`)
    ///   keeps the fast cold-load path that the Quick Look preview opens with;
    ///   4D navigation re-parses with `true` once the user scrolls past volume 0.
    ///   A no-op for every other kind (uncompressed `.nii` is mmap'd; `.mgz` /
    ///   `.mif.gz` already decompress in full).
    public func parse(url: URL, fullyDecompress: Bool = false) throws -> MIQImage {
        let (data, kind) = try loadAndDecompress(url: url, fullyDecompress: fullyDecompress)
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

    private func loadAndDecompress(url: URL, fullyDecompress: Bool = false) throws -> (Data, MIQFileKind) {
        guard let kind = MIQFileKind(url: url) else {
            throw MIQError.unsupportedFileFormat
        }

        // Network volumes can't be memory-mapped: `.mappedIfSafe` falls back to a
        // full read into RAM, so even our capped gunzip first pulls every byte off
        // the wire. When the cold preview is bounded to a volume-0 prefix
        // (canonical NIfTI), read only that prefix from disk instead. Local disk
        // keeps the proven mmap + demand-paging path unchanged (zero perf risk),
        // and the 4D `fullyDecompress: true` re-parse always uses it.
        //
        // Only NIfTI can be bounded, so gate on kind *before* the `statfs`
        // locality probe — `.mgz`/`.mif`/`.nrrd` skip it entirely and pay nothing.
        if !fullyDecompress, kind == .nii || kind == .niiGz, !VolumeLocation.isLocal(url),
           let bounded = try? loadBoundedNiftiPrefix(url: url, kind: kind) {
            return (bounded, kind)
        }

        let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard kind.isCompressed else {
            return (raw, kind)
        }
        guard MIQBinaryReader.isLikelyGzip(raw) else {
            throw MIQError.malformedFile("file extension claims gzip but the gzip magic bytes are missing")
        }

        // Decompress only the prefix the preview actually reads, when the layout
        // makes that a bounded prefix. Otherwise (or when the caller explicitly
        // needs every volume, e.g. 4D navigation) fall back to full decompression.
        if !fullyDecompress, let budget = niftiVolumeZeroBudget(raw: raw, kind: kind) {
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
    /// The cold preview only ever reads volume 0 (cache-hit/first-frame paths
    /// pin volumeIndex 0; scrolling moves only x/y/z), and NIfTI stores time as
    /// the outermost (slowest) axis with no strides, so this budget is exactly
    /// sufficient and never short for that path. For 3D NIfTI it equals the full
    /// payload. 4D navigation deliberately steps outside this budget — it
    /// re-parses with `fullyDecompress: true` (which skips this cap) before
    /// reading volumes > 0, so the capped buffer is never sampled past volume 0.
    private func niftiVolumeZeroBudget(raw: Data, kind: MIQFileKind) -> Int? {
        guard kind == .niiGz,
              let probe = try? MIQBinaryReader.gunzip(raw, maxOutputBytes: Self.headerProbeBytes) else {
            return nil
        }
        return niftiBudget(fromHeaderProbe: probe)
    }

    /// Volume-0 byte budget (`vox_offset + W·H·D·bytesPerVoxel`) computed from an
    /// already-decompressed NIfTI header probe. `nil` when the header can't be
    /// parsed or the dimensions are degenerate — the caller then falls back to a
    /// full read. Shared by the in-memory (`niftiVolumeZeroBudget`) and the
    /// streaming network paths so both bound to exactly the same prefix.
    private func niftiBudget(fromHeaderProbe probe: Data) -> Int? {
        guard let header = try? parseNiftiHeader(from: probe) else { return nil }
        let volumeElements = header.width * header.height * header.depth
        let payloadBytes = volumeElements * header.datatype.bytesPerVoxel
        guard volumeElements > 0, payloadBytes > 0 else { return nil }
        let budget = header.voxOffset + payloadBytes
        return budget > 0 ? budget : nil
    }

    /// Reads only the volume-0 prefix of a canonical NIfTI from disk, so a remote
    /// volume never streams the whole (possibly multi-volume) file for a cold
    /// preview. Returns `nil` for kinds whose volume 0 isn't a file prefix
    /// (`.mgz`/`.mif.gz` — arbitrary strides; `.nrrd`) so the caller falls back to
    /// the full read. `internal` for direct unit testing (the production gate is
    /// `isLocalVolume`, which a local temp file would skip).
    func loadBoundedNiftiPrefix(url: URL, kind: MIQFileKind) throws -> Data? {
        switch kind {
        case .nii:
            return try boundedUncompressedNiftiPrefix(url: url)
        case .niiGz:
            return try boundedCompressedNiftiPrefix(url: url)
        default:
            return nil
        }
    }

    /// Uncompressed `.nii`: parse the header from a small probe, then read exactly
    /// `vox_offset + volume-0 bytes` from offset 0. For 3D that's the whole file
    /// (no change); for 4D it skips every volume past the first. A file shorter
    /// than the budget yields what exists — the parser's out-of-range reads return
    /// the zero backstop, same as the gz cap.
    private func boundedUncompressedNiftiPrefix(url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let probe = try handle.read(upToCount: Self.headerProbeBytes), !probe.isEmpty,
              let budget = niftiBudget(fromHeaderProbe: probe) else {
            return nil
        }
        if budget <= probe.count {
            return Data(probe.prefix(budget))
        }
        var data = probe
        if let more = try handle.read(upToCount: budget - probe.count) {
            data.append(more)
        }
        return data
    }

    /// Compressed `.nii.gz`: stream-inflate from disk, stopping once the header is
    /// available and the volume-0 budget is produced. If the budget can't be
    /// resolved (non-canonical header), the stream runs to completion and the full
    /// payload is returned — still valid for the parser.
    private func boundedCompressedNiftiPrefix(url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var budget: Int?
        var budgetResolved = false
        let prefix = try MIQBinaryReader.gunzip(from: handle) { produced in
            if !budgetResolved, produced.count >= Self.headerProbeBytes {
                budget = self.niftiBudget(fromHeaderProbe: produced)
                budgetResolved = true
            }
            if let budget { return produced.count >= budget }
            return false
        }
        return prefix.isEmpty ? nil : prefix
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
