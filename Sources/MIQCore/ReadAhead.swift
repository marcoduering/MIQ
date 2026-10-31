import Foundation

/// Read-ahead for local files: `F_RDADVISE` hints, so the kernel pulls the bytes a
/// preview is about to touch in large sequential reads instead of one page fault
/// at a time through the memory map. Measured Oct 2026 (M2 Pro, internal SSD, file
/// not in the page cache): faulting in a 203 MB `.mif` took 226 ms, the same pages
/// after the hint 32 ms; a 22 MB `.nii` 25 → 3.6 ms. A file already in the page
/// cache is unaffected, and the corpus profile's warm stages never see either.
///
/// A hint only: it never changes the bytes the parser sees, and a failed call
/// leaves today's page faults. What it can get wrong is the *range* — advising
/// bytes the preview never touches turns the ~3 MB volume-0 read of a 4D file into
/// a whole-file read — so the range functions are the part that needs care, and
/// they are pure so tests can pin them.
enum ReadAhead {
    /// Largest length one `F_RDADVISE` call takes (`ra_count` is an Int32).
    static let maxAdviseChunk = 1 << 30

    /// The bytes of `fileData` that volume 0 of `image` occupies — from the payload
    /// offset through the last voxel of volume 0, which for every layout MIQ reads
    /// (strides are always positive) covers each voxel of volume 0 and nothing of
    /// later volumes when time is the outermost axis. A volume-interleaved MIF
    /// (time stride 1) gets nearly the whole file, of which the center slices may
    /// touch only part (a 720 MB DWI `.mif`: about half). Advised anyway, uncapped:
    /// reading the whole extent sequentially still beats faulting in the touched
    /// half (measured ~0.5 s faulted), and a local uncompressed parse can't be
    /// cancelled, so the pages the decode needs are read either way.
    ///
    /// `nil` unless the image's storage *is* `fileData`: a MIF `bit` payload, a
    /// gzip-encoded NRRD or a compressed MetaImage is decoded into a fresh buffer
    /// at parse time, so its offsets aren't file offsets — and the parse has
    /// already read the file.
    static func volumeZeroRange(of image: MIQImage, fileData: Data) -> Range<Int>? {
        guard sharesBuffer(image.storage, fileData) else { return nil }
        let header = image.header
        guard header.width > 0, header.height > 0, header.depth > 0 else { return nil }
        let lastElement = image.voxelElementIndex(
            x: header.width - 1, y: header.height - 1, z: header.depth - 1, t: 0
        )
        let (bytes, overflow) = (lastElement + 1).multipliedReportingOverflow(by: header.datatype.bytesPerVoxel)
        guard !overflow, bytes > 0 else { return nil }
        let start = image.payloadOffset
        // The parsers guard only that volume 0 is present, not that the file ends
        // there, and a truncated file must not advise past its end.
        let (end, endOverflow) = start.addingReportingOverflow(bytes)
        let upper = endOverflow ? fileData.count : Swift.min(end, fileData.count)
        guard upper > start else { return nil }
        return start..<upper
    }

    /// Whether a compressed file is read ahead before inflating it: when the whole
    /// stream will be inflated, not when only a prefix will be. A capped `.nii.gz`
    /// load inflates the whole stream exactly when its volume-0 budget reaches the
    /// gzip size hint — i.e. a 3D file. The hint wraps at 4 GiB, so a stream over
    /// 4 GiB can look whole when it isn't; `Rolling` then stops advising when the
    /// capped inflate stops consuming input, so that costs at most `lead + step`.
    static func readsAheadCompressed(fileSize: Int, volumeZeroBudget: Int?, isizeHint: UInt32?) -> Bool {
        guard fileSize > 0 else { return false }
        if let volumeZeroBudget {
            guard let isizeHint else { return false }
            return volumeZeroBudget >= Int(isizeHint)
        }
        return true
    }

    /// Issues the hint for `range` of the file at `url`. The read is queued on the
    /// file, not the descriptor, so closing it straight away doesn't cancel it
    /// (checked with a cold 61 MB file: 9.8 ms after close).
    static func advise(_ url: URL, range: Range<Int>) {
        guard !range.isEmpty else { return }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        advise(fd: fd, range: range)
    }

    /// `range` split into `F_RDADVISE`-sized pieces, in order.
    static func chunks(of range: Range<Int>) -> [Range<Int>] {
        stride(from: range.lowerBound, to: range.upperBound, by: maxAdviseChunk).map {
            $0..<Swift.min($0 + maxAdviseChunk, range.upperBound)
        }
    }

    fileprivate static func advise(fd: Int32, range: Range<Int>) {
        for chunk in chunks(of: range) {
            var advisory = radvisory(ra_offset: off_t(chunk.lowerBound), ra_count: Int32(chunk.count))
            _ = fcntl(fd, F_RDADVISE, &advisory)
        }
    }

    private static func sharesBuffer(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, a.startIndex == 0, b.startIndex == 0 else { return false }
        return a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in pa.baseAddress == pb.baseAddress }
        }
    }

    /// Read-ahead that follows an inflate through a compressed file: it keeps the
    /// next `lead` bytes past what zlib has consumed advised, a `step` at a time
    /// (so between `lead` and `lead + step` are ahead of it at any moment).
    /// Inflate consumes its input front to back, so this reads the file at disk
    /// speed just ahead of the decompressor. Rolling rather than one whole-file
    /// hint because a hint can't be withdrawn: when a preview is dismissed the
    /// inflate stops at its next output window, leaving at most `lead + step`
    /// (6 MiB) advised and unread rather than the rest of the file.
    ///
    /// The lead is small on purpose: every advised byte a dismissed preview never
    /// uses holds the disk for the next file, and on an external HDD a large first
    /// hint also queues ahead of inflate's own page faults. Measured Oct 2026 on a
    /// cold 611 MB `dwi.mif.gz` (median of 3–5), 64 MiB steps vs these: internal
    /// SSD 1.55 vs 1.59 s, external Thunderbolt SSD 1.77 vs 1.69 s, exFAT on the
    /// same SSD 1.65 s both, USB HDD ~6.5 s both. Dismissed after 1 s, 64 MiB steps
    /// had read 120–170 MiB past the decompressor, these 1–1.5 MiB; on the HDD,
    /// inflate had consumed only 9 MiB behind the 128 MiB first hint, 99 MiB
    /// behind these. Progress arrives once per output window, so the lead must
    /// cover the input one window consumes: with 16 MiB windows, steps under 8 MiB
    /// fell behind (2 MiB: 1.95 s), hence the 4 MiB `inflateOutputWindow`.
    final class Rolling {
        static let step = 2 << 20
        static let lead = 2 * step

        private let fd: Int32
        private let fileSize: Int
        private var advisedUpTo = 0

        init?(url: URL, fileSize: Int) {
            guard fileSize > 0 else { return nil }
            let fd = open(url.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            self.fd = fd
            self.fileSize = fileSize
        }

        deinit { close(fd) }

        /// Called with zlib's `total_in` before each output window.
        func inputConsumed(_ consumed: Int) {
            guard let range = Self.nextRange(consumed: consumed, advisedUpTo: advisedUpTo, fileSize: fileSize) else {
                return
            }
            ReadAhead.advise(fd: fd, range: range)
            advisedUpTo = range.upperBound
        }

        /// The range to advise so that at least `lead` bytes past `consumed` are
        /// covered, in whole steps from `advisedUpTo` and clipped to the file.
        /// `nil` when enough is advised already.
        static func nextRange(consumed: Int, advisedUpTo: Int, fileSize: Int) -> Range<Int>? {
            let target = Swift.min(consumed + lead, fileSize)
            guard advisedUpTo < target else { return nil }
            let steps = (target - advisedUpTo + step - 1) / step
            return advisedUpTo..<Swift.min(advisedUpTo + steps * step, fileSize)
        }
    }
}
