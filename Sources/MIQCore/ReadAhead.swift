import Foundation

/// Read-ahead for local files: one `F_RDADVISE` hint, so the kernel pulls the bytes
/// a preview is about to touch in large sequential reads instead of one page fault
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
    /// Upper bound on one advisory read. Bytes past it are still read, as page
    /// faults, if the parse gets that far. The hint can't be withdrawn, whereas a
    /// cancelled decompression stops faulting, so this bounds the I/O a dismissed
    /// preview leaves queued (~40 ms of an internal SSD, seconds of a USB disk).
    static let maxAdvisedBytes = 256 << 20

    /// The bytes of `fileData` that volume 0 of `image` occupies — from the payload
    /// offset through the last voxel of volume 0, which for every layout MIQ reads
    /// (strides are always positive) covers each voxel of volume 0 and nothing of
    /// later volumes when time is the outermost axis. A volume-interleaved MIF
    /// (time stride 1) gets nearly the whole file, which its decode touches anyway.
    ///
    /// `nil` unless the image's storage *is* `fileData`: a MIF `bit` payload or a
    /// gzip-encoded NRRD is decoded into a fresh buffer at parse time, so its
    /// offsets aren't file offsets — and the parse has already read the file.
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

    /// The bytes of a compressed file to advise before inflating it: all of them
    /// when the whole stream will be inflated, none when only a prefix will be.
    /// A capped `.nii.gz` load inflates the whole stream exactly when its volume-0
    /// budget reaches the gzip size hint — i.e. a 3D file. The hint wraps at 4 GiB,
    /// so a stream over 4 GiB can look whole when it isn't; that over-advises, and
    /// `maxAdvisedBytes` bounds it.
    static func compressedRange(fileSize: Int, volumeZeroBudget: Int?, isizeHint: UInt32?) -> Range<Int>? {
        guard fileSize > 0 else { return nil }
        if let volumeZeroBudget {
            guard let isizeHint, volumeZeroBudget >= Int(isizeHint) else { return nil }
        }
        return 0..<fileSize
    }

    /// Issues the hint for `range` of the file at `url`, capped at `maxAdvisedBytes`.
    /// The read is queued on the file, not the descriptor, so closing it straight
    /// away doesn't cancel it (checked with a cold 61 MB file: 9.8 ms after close).
    static func advise(_ url: URL, range: Range<Int>) {
        let range = capped(range)
        guard !range.isEmpty else { return }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // `ra_count` is an Int32; the cap keeps every range well inside it.
        var advisory = radvisory(ra_offset: off_t(range.lowerBound), ra_count: Int32(range.count))
        _ = fcntl(fd, F_RDADVISE, &advisory)
    }

    static func capped(_ range: Range<Int>) -> Range<Int> {
        range.lowerBound..<Swift.min(range.upperBound, range.lowerBound + maxAdvisedBytes)
    }

    private static func sharesBuffer(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count, a.startIndex == 0, b.startIndex == 0 else { return false }
        return a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in pa.baseAddress == pb.baseAddress }
        }
    }
}
