import Foundation

public struct MIQParser {
    /// Called once a file on a network volume has been read from the mount — before
    /// decompression and decoding, which need no further I/O. Lets the preview's
    /// network read lane hand the link to the next file early. Never called for a
    /// local file.
    let onNetworkReadFinished: (@Sendable () -> Void)?
    /// Hint the kernel to read ahead what the parse and the center-slice decode
    /// will touch of a *local* file (see `ReadAhead`). Off by default; the preview
    /// turns it on. The thumbnail extension leaves it off: Finder requests many
    /// icons at once, and each hint queues reads that can't be withdrawn.
    let readsAhead: Bool

    public init(onNetworkReadFinished: (@Sendable () -> Void)? = nil, readsAhead: Bool = false) {
        self.onNetworkReadFinished = onNetworkReadFinished
        self.readsAhead = readsAhead
    }

    /// - Parameter fullyDecompress: When `true`, bypass the volume-0 budget cap
    ///   for `.nii.gz` and decompress the entire stream. The default (`false`)
    ///   keeps the fast cold-load path that the Quick Look preview opens with;
    ///   4D navigation re-parses with `true` once the user scrolls past volume 0.
    ///   A no-op for every other kind (uncompressed `.nii` is mmap'd; `.mgz` /
    ///   `.mif.gz` already decompress in full).
    public func parse(url: URL, fullyDecompress: Bool = false) throws -> MIQImage {
        let (data, kind, isLocal) = try loadAndDecompress(url: url, fullyDecompress: fullyDecompress)
        let image = try parseImage(data: data, kind: kind)
        // An uncompressed local file is still only mapped: the header parse
        // touched a page or two, and the decode that follows faults in the rest.
        if readsAhead, isLocal, !kind.isCompressed,
           let range = ReadAhead.volumeZeroRange(of: image, fileData: data) {
            ReadAhead.advise(url, range: range)
        }
        return image
    }

    /// Whether the file stores its payload raw, for the thumbnail size gate. For
    /// the kinds whose header decides (`MIQFileKind.headerDecidesCompression`)
    /// this reads only the header; for every other kind the extension says.
    public static func hasRawPayload(at url: URL, kind: MIQFileKind) -> Bool {
        switch kind {
        case .nrrd: return nrrdHasRawPayload(at: url)
        case .mha: return metaImageHasRawPayload(at: url)
        default: return !kind.isCompressed
        }
    }

    // MARK: - Internal

    /// Generous prefix that comfortably contains any NIfTI fixed header (≤ 540 B)
    /// plus typical extensions — enough to compute the payload budget cheaply.
    private static let headerProbeBytes = 64 * 1024

    /// Chunk size for the cancelable network reads. Cancellation is only checked
    /// between chunks, so this bounds how long a dismissed preview keeps pulling:
    /// measured on a contended SMB mount, one 4 MB read took up to ~2 s. 2 MB halves
    /// that worst case while keeping the round-trip count per MB low enough for a
    /// fast share. Local files never reach these reads (they are memory-mapped).
    private static let networkReadChunkBytes = 2 * 1024 * 1024

    private func loadAndDecompress(url: URL, fullyDecompress: Bool = false) throws -> (Data, MIQFileKind, isLocal: Bool) {
        guard let kind = MIQFileKind(url: url) else {
            throw MIQError.unsupportedFileFormat
        }

        // `statfs` locality probe (cheap, one syscall). Now probed for every kind,
        // not just NIfTI: non-boundable kinds (`.mgz`/`.mif.gz`/`.nrrd`/`.mha`) can't read
        // a volume-0 prefix, so on a network volume they fall back to a full read —
        // which must be cancelable (see below), and that needs the locality answer.
        let isLocal = VolumeLocation.isLocal(url)

        // Network volumes can't be memory-mapped: `.mappedIfSafe` falls back to a
        // full read into RAM, so even our capped gunzip first pulls every byte off
        // the wire. When the cold preview is bounded to a volume-0 prefix
        // (canonical NIfTI), read only that prefix from disk instead. Local disk
        // keeps the proven mmap + demand-paging path unchanged (zero perf risk),
        // and the 4D `fullyDecompress: true` re-parse always uses it.
        if !fullyDecompress, kind == .nii || kind == .niiGz, !isLocal {
            do {
                if let bounded = try loadBoundedNiftiPrefix(url: url, kind: kind) {
                    onNetworkReadFinished?()
                    return (bounded, kind, false)
                }
            } catch is CancellationError {
                // The bounded reads poll cancellation; don't let the fallback
                // below restart the pull the dismissed preview just abandoned.
                throw CancellationError()
            } catch {
                // Any other bounded-read failure falls back to the full read.
            }
        }

        // Local volume: mmap + demand paging, so the parse and decode read only the
        // pages they touch. `.alwaysMapped`, not `.mappedIfSafe`: Foundation deems
        // only the internal disk "safe" and reads a file on any external drive in
        // full, uncancelably, before the parse starts (Thunderbolt SSD, USB HDD,
        // exFAT alike). Mapped, a cold 4D `.nii.gz` there reads 2–3 MiB instead of
        // 225 MiB (7× faster on SSD, 14× on HDD) and a 755 MB `.mif` costs ~1 MiB
        // of footprint instead of 721 MiB (measured Oct 2026). The price is the
        // reason Foundation is careful: a drive pulled mid-preview takes the mapped
        // pages with it. Tested by hand (Oct 2026): pulling empties the preview
        // immediately and the next preview works; a normal eject closes the
        // preview first and then ejects.
        // Network volume: never mapped — a dropped link would be the same crash,
        // and the read must stay cancelable: an uncancelable full read of a large
        // `.mif.gz` pins the (already slow) link until completion, stalling
        // Finder's own I/O on the same mount even after the user dismisses the
        // preview. Read in cancelable chunks so a cancelled parse stops pulling.
        let raw = isLocal
            ? try Data(contentsOf: url, options: [.alwaysMapped])
            : try readCancelable(url: url)
        if !isLocal { onNetworkReadFinished?() }
        guard kind.isCompressed else {
            return (raw, kind, isLocal)
        }
        guard MIQBinaryReader.isLikelyGzip(raw) else {
            throw MIQError.malformedFile("file extension claims gzip but the gzip magic bytes are missing")
        }

        // Decompress only the prefix the preview actually reads, when the layout
        // makes that a bounded prefix. Otherwise (or when the caller explicitly
        // needs every volume, e.g. 4D navigation) fall back to full decompression.
        let budget = fullyDecompress ? nil : niftiVolumeZeroBudget(raw: raw, kind: kind)
        // Inflate reads the mapped compressed bytes front to back, faulting them in
        // one page at a time; read ahead of it, unless only a prefix is inflated.
        let rolling = readsAhead && isLocal
            && ReadAhead.readsAheadCompressed(fileSize: raw.count, volumeZeroBudget: budget,
                                              isizeHint: MIQBinaryReader.gzipSizeHint(raw))
            ? ReadAhead.Rolling(url: url, fileSize: raw.count)
            : nil
        let onInputProgress = rolling.map { rolling in { (consumed: Int) in rolling.inputConsumed(consumed) } }
        if let budget {
            return (try MIQBinaryReader.gunzip(raw, maxOutputBytes: budget, onInputProgress: onInputProgress), kind, isLocal)
        }
        return (try MIQBinaryReader.gunzip(raw, onInputProgress: onInputProgress), kind, isLocal)
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
        // `validateDimensionExtent` bounds the dims product, but *not* `voxOffset`
        // — that field is header-supplied and can legitimately reach `Int.max`
        // (NIfTI-1's float `vox_offset` clamps there via `safeInt`; NIfTI-2 reads a
        // raw Int64), so a plain `+` traps and crashes the extension. `nil` falls
        // back to full decompression, where `parseNifti`'s `data.count >= voxOffset`
        // guard rejects the file cleanly.
        let (budget, overflow) = header.voxOffset.addingReportingOverflow(payloadBytes)
        guard !overflow, budget > 0 else { return nil }
        return budget
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
        return try withThrottledIO {
            guard let probe = try handle.read(upToCount: Self.headerProbeBytes), !probe.isEmpty,
                  let budget = niftiBudget(fromHeaderProbe: probe) else {
                return nil
            }
            if budget <= probe.count {
                return Data(probe.prefix(budget))
            }
            // Chunked rather than one `read(upToCount: budget - probe.count)`: for a
            // 3D `.nii` the volume-0 budget *is* the whole file, so on a slow mount
            // that single read is exactly the uncancelable full pull this path
            // exists to avoid. Cancellation is checked per chunk, as in
            // `readCancelable`.
            var data = probe
            while data.count < budget {
                try Task.checkCancellation()
                let want = Swift.min(Self.networkReadChunkBytes, budget - data.count)
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                    break // file shorter than the budget — parser's zero backstop covers it
                }
                data.append(chunk)
            }
            return data
        }
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
        // `gunzip(from:)` checks cancellation per input chunk, so a dismissed
        // preview stops pulling compressed bytes off the wire.
        let prefix = try withThrottledIO {
            try MIQBinaryReader.gunzip(from: handle) { produced in
                if !budgetResolved, produced.count >= Self.headerProbeBytes {
                    budget = self.niftiBudget(fromHeaderProbe: produced)
                    budgetResolved = true
                }
                if let budget { return produced.count >= budget }
                return false
            }
        }
        return prefix.isEmpty ? nil : prefix
    }

    /// Reads the whole file in cancelable chunks, the network-volume substitute
    /// for `Data(contentsOf:.mappedIfSafe)` (which can't map a network file and so
    /// degrades to one uncancelable full read). `Task.checkCancellation()` between
    /// chunks lets a dismissed/replaced preview's cancelled parse task stop pulling
    /// bytes immediately, freeing the slow link for Finder. Capacity is reserved
    /// from the file size to avoid repeated reallocations of a large buffer.
    private func readCancelable(url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        return try withThrottledIO {
            var data = Data()
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                data.reserveCapacity(size)
            }
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: Self.networkReadChunkBytes), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
            return data
        }
    }

    /// Runs `body` with this thread's disk I/O deprioritized, so that pulling a
    /// file off a network mount doesn't starve Finder's foreground filesystem
    /// calls on the same mount (the freeze symptom). Per-thread policy is safe
    /// here: every caller reads to completion on one cooperative-pool thread with
    /// no `await` inside, and `defer` restores the prior policy on that same
    /// thread. Best-effort — throttling biases the *local* I/O scheduler, so it
    /// eases contention more than it cures a fully network-bound stall.
    private func withThrottledIO<T>(_ body: () throws -> T) rethrows -> T {
        let previousPolicy = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        defer {
            setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, previousPolicy >= 0 ? previousPolicy : IOPOL_DEFAULT)
        }
        return try body()
    }

    /// Non-finite `scl_slope`/`scl_inter` mean "no scaling", which NIfTI already
    /// spells as slope 0 — so normalise the pair to 0/0 and reuse the unscaled path.
    ///
    /// Not corrupt-header hardening: NaN is nibabel's marker for "scaling
    /// undefined" (`set_slope_inter(None, None)` writes it, and its own reader maps
    /// a non-finite slope back to "no scaling"), so such files are ordinary output
    /// from the most widely used NIfTI toolchain. Without this they are destroyed
    /// rather than mis-scaled — `slope != 0` is TRUE for NaN, so every voxel becomes
    /// NaN, no window can be derived, and the file renders black with the Scaling
    /// row *hidden* (`MIQMetadata`'s `abs(slope) > epsilon` is also false for NaN).
    ///
    /// Dropped as a pair: a finite slope with a NaN intercept is equally unusable.
    func normalizedScaling(slope: Float, inter: Float) -> (slope: Float, inter: Float) {
        (slope.isFinite && inter.isFinite) ? (slope, inter) : (0, 0)
    }

    /// Rejects a header whose declared voxel extent (`dims` product × bytes per
    /// voxel) overflows `Int`. A corrupt or crafted header can list dimensions
    /// whose product exceeds `Int.max`; computing it with `*` traps and crashes
    /// the sandboxed extension. Throwing `invalidDimensions` instead lets the
    /// preview fail gracefully. This is purely an arithmetic representability
    /// guard — it does *not* assert the payload is present, so the bounded NIfTI
    /// cold-load path (which holds only volume 0) is unaffected. Validating here,
    /// in each format's earliest shared header-parse step, also protects every
    /// downstream product (axis strides, element counts, `containsAllVolumes`,
    /// `voxelElementIndex`), since each is ≤ this total.
    func validateDimensionExtent(_ dims: [Int], bytesPerVoxel: Int) throws {
        var product = Swift.max(1, bytesPerVoxel)
        for dim in dims {
            let (next, overflow) = product.multipliedReportingOverflow(by: dim)
            guard !overflow else { throw MIQError.invalidDimensions }
            product = next
        }
    }

    /// Cleans a header's free-text description into `MIQHeader.comment`: each part is
    /// cut at its first NUL (NIfTI pads `descrip` with NULs, sometimes followed by
    /// junk), control characters become spaces, whitespace is trimmed and empty parts
    /// are dropped. The parts are joined with "\n"; `nil` when nothing is left.
    static func headerComment(_ parts: [String]) -> String? {
        let lines = parts.compactMap { part -> String? in
            let cut = part.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let cleaned = String(String.UnicodeScalarView(cut.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) ? " " : $0
            }))
            let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `headerComment` for a fixed-size byte field (NIfTI `descrip`), decoded as
    /// UTF-8 with invalid bytes replaced.
    static func headerComment(_ data: Data, offset: Int, length: Int) -> String? {
        let start = data.startIndex + offset
        guard data.count >= offset + length else { return nil }
        return headerComment([String(decoding: data[start..<start + length], as: UTF8.self)])
    }

    private func parseImage(data: Data, kind: MIQFileKind) throws -> MIQImage {
        switch kind {
        case .nii, .niiGz:
            return try parseNifti(data, compressed: kind.isCompressed)
        case .mgh, .mgz:
            return try parseMgh(data)
        case .mif, .mifGz:
            return try parseMif(data)
        case .nrrd:
            return try parseNrrd(data)
        case .mha:
            return try parseMetaImage(data)
        }
    }
}
