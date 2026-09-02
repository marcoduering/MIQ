import Foundation
import zlib

enum MIQBinaryReader {
    static func int16(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> Int16 {
        return Int16(bitPattern: uint16(data, offset, littleEndian: littleEndian))
    }

    static func int32(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> Int32 {
        return Int32(bitPattern: uint32(data, offset, littleEndian: littleEndian))
    }

    static func float32(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> Float {
        return Float(bitPattern: uint32(data, offset, littleEndian: littleEndian))
    }

    static func int16Array(_ data: Foundation.Data, _ offset: Int, count: Int, littleEndian: Bool) -> [Int16] {
        return (0..<count).map { index in
            int16(data, offset + index * MemoryLayout<Int16>.size, littleEndian: littleEndian)
        }
    }

    static func float32Array(_ data: Foundation.Data, _ offset: Int, count: Int, littleEndian: Bool) -> [Float] {
        return (0..<count).map { index in
            float32(data, offset + index * MemoryLayout<Float>.size, littleEndian: littleEndian)
        }
    }

    static func int64(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> Int64 {
        return Int64(bitPattern: uint64(data, offset, littleEndian: littleEndian))
    }

    static func float64(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> Double {
        return Double(bitPattern: uint64(data, offset, littleEndian: littleEndian))
    }

    static func int64Array(_ data: Foundation.Data, _ offset: Int, count: Int, littleEndian: Bool) -> [Int64] {
        return (0..<count).map { index in
            int64(data, offset + index * MemoryLayout<Int64>.size, littleEndian: littleEndian)
        }
    }

    static func float64Array(_ data: Foundation.Data, _ offset: Int, count: Int, littleEndian: Bool) -> [Double] {
        return (0..<count).map { index in
            float64(data, offset + index * MemoryLayout<Double>.size, littleEndian: littleEndian)
        }
    }

    /// `Float`→`Int` that never traps. NaN/infinite or out-of-`Int`-range inputs
    /// map to 0; finite in-range values truncate toward zero. A corrupt NIfTI
    /// header can put NaN/inf or a huge value in the float `vox_offset` field,
    /// where a plain `Int(Float)` would trap and crash the sandboxed extension.
    static func safeInt(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Float(Int.max) { return Int.max }
        if value <= Float(Int.min) { return Int.min }
        return Int(value)
    }

    static func isLikelyGzip(_ data: Foundation.Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }
        return data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Initial output capacity for an in-memory inflate.
    ///
    /// The gzip trailer's ISIZE field is the uncompressed size **mod 2^32**, so it
    /// wraps for any stream over 4 GiB — it is a sizing hint only and can never
    /// bound the output. (Trusting it as a bound silently produced a short payload:
    /// a >4 GiB volume rendered with missing data and no error.) The stream's real
    /// end is what zlib validates the trailer against at `Z_STREAM_END`.
    ///
    /// The ratio bound keeps `avail_out` proportionate to the input so a bogus hint
    /// can't hand inflate a wildly oversized first window — DEFLATE expands at most
    /// ~1032:1, so 1100 is never under-allocated for a legitimate stream. The floor
    /// keeps a hint that wrapped to zero (a stream whose size is an exact multiple
    /// of 4 GiB) from starting at nothing.
    ///
    /// Over-allocating is cheap: measured Aug 2026, `Data(count:)` is demand-zeroed,
    /// so even `Data(count: 4 GB)` moves `phys_footprint` (what jetsam reads) by
    /// 0.0 MB; pages cost only what inflate actually writes. A lying trailer
    /// therefore buys an attacker virtual address space and nothing else.
    ///
    /// Not defended against: a *genuine* bomb (~4 MB inflating to ~4 GB), which does
    /// commit every page. That is deliberate — real sparse volumes (a mostly-zero
    /// segmentation mask) reach comparable ratios, so any bound tight enough to
    /// catch a bomb would reject legitimate data. The failure mode is a
    /// jetsam-killed short-lived preview extension: no data loss, no code execution,
    /// system recovers.
    static let inflateCapacityFloor = 1 << 16

    static func initialInflateCapacity(compressedCount: Int, isize: UInt32) -> Int {
        var capacity = Int(isize)
        let ratioBound = compressedCount.multipliedReportingOverflow(by: 1100)
        if !ratioBound.overflow {
            capacity = Swift.min(capacity, ratioBound.partialValue)
        }
        return Swift.max(capacity, inflateCapacityFloor)
    }

    static func gunzip(_ data: Foundation.Data) throws -> Foundation.Data {
        guard data.count >= 18 else {
            throw MIQError.decompressionFailed
        }

        var stream = z_stream()
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw MIQError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        // Gzip trailer: last 4 bytes = ISIZE (uncompressed size mod 2^32,
        // little-endian). It seeds the first allocation and nothing else — see
        // `initialInflateCapacity`. The buffer grows until zlib reports the stream
        // end, so a wrapped or patched trailer costs a realloc, never a short read.
        let isize = data.withUnsafeBytes { bytes -> UInt32 in
            bytes.loadUnaligned(fromByteOffset: data.count - 4, as: UInt32.self)
        }.littleEndian

        var capacity = initialInflateCapacity(compressedCount: data.count, isize: isize)
        var output = Data(count: capacity)
        var produced = 0
        var status: Int32 = Z_OK

        data.withUnsafeBytes { inBuf in
            guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress else {
                status = Z_DATA_ERROR
                return
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = UInt32(data.count)

            while true {
                status = output.withUnsafeMutableBytes { outBuf -> Int32 in
                    guard let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_DATA_ERROR
                    }
                    // `avail_out` is a UInt32, so a buffer past 4 GiB is filled in windows.
                    let window = Swift.min(capacity - produced, Int(UInt32.max))
                    stream.next_out = outBase + produced
                    stream.avail_out = UInt32(window)
                    let ret = inflate(&stream, Z_NO_FLUSH)
                    produced += window - Int(stream.avail_out)
                    return ret
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR { break }
                if stream.avail_out > 0 {
                    // Output space left but no stream end: the compressed input ran
                    // out first, so the file is truncated.
                    status = Z_DATA_ERROR
                    break
                }
                if produced < capacity { continue }  // buffer has room, just refill the window
                let grown = capacity.multipliedReportingOverflow(by: 2)
                guard !grown.overflow else {
                    status = Z_MEM_ERROR
                    break
                }
                capacity = grown.partialValue
                output.count = capacity              // growth is what guarantees forward progress
            }
        }

        guard status == Z_STREAM_END else {
            throw MIQError.decompressionFailed
        }

        if produced < output.count {
            output.removeLast(output.count - produced)
        }
        return output
    }

    /// Streaming gunzip that stops once at least `maxOutputBytes` have been
    /// produced (or the stream ends first). Used to decompress only the prefix a
    /// Quick Look preview actually reads (header + the requested volume) instead
    /// of the whole — often 100x less work for 4D files. Producing exactly the
    /// requested cap is a deliberate success, not a truncation error.
    ///
    /// For the full-stream case (cap >= uncompressed size) the chunked inflate
    /// produces byte-identical output to the single-shot `gunzip(_:)` above.
    static func gunzip(_ data: Foundation.Data, maxOutputBytes: Int) throws -> Foundation.Data {
        guard data.count >= 18, maxOutputBytes >= 1 else {
            throw MIQError.decompressionFailed
        }

        var stream = z_stream()
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw MIQError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        let isize = data.withUnsafeBytes { bytes -> UInt32 in
            bytes.loadUnaligned(fromByteOffset: data.count - 4, as: UInt32.self)
        }.littleEndian

        // ISIZE only seeds the allocation (it wraps at 4 GiB — see
        // `initialInflateCapacity`). `maxOutputBytes` is the caller's contract and
        // the sole hard ceiling on what this produces.
        var capacity = Swift.min(
            initialInflateCapacity(compressedCount: data.count, isize: isize),
            maxOutputBytes
        )
        var output = Data(count: capacity)
        var produced = 0
        var status: Int32 = Z_OK

        data.withUnsafeBytes { inBuf in
            guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress else {
                status = Z_DATA_ERROR
                return
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = UInt32(data.count)

            while true {
                status = output.withUnsafeMutableBytes { outBuf -> Int32 in
                    guard let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_DATA_ERROR
                    }
                    let window = Swift.min(capacity - produced, Int(UInt32.max))
                    stream.next_out = outBase + produced
                    stream.avail_out = UInt32(window)
                    let ret = inflate(&stream, Z_NO_FLUSH)
                    produced += window - Int(stream.avail_out)
                    return ret
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR { break }
                if stream.avail_out > 0 { break }       // input ended before the stream did
                if produced < capacity { continue }     // buffer has room, refill the window
                if capacity == maxOutputBytes { break } // requested prefix produced: deliberate stop
                let grown = capacity.multipliedReportingOverflow(by: 2)
                capacity = grown.overflow ? maxOutputBytes : Swift.min(grown.partialValue, maxOutputBytes)
                output.count = capacity
            }
        }

        // Success: the whole stream decompressed, OR we filled the requested cap
        // (a deliberate early stop). Z_BUF_ERROR with a filled cap is expected —
        // it means "no output space left", which is exactly why we stopped.
        guard status == Z_STREAM_END || produced == maxOutputBytes else {
            throw MIQError.decompressionFailed
        }
        if produced < output.count {
            output.removeLast(output.count - produced)
        }
        return output
    }

    /// Streaming gunzip that pulls compressed bytes from `handle` in chunks and
    /// stops as soon as `hasEnough(produced)` returns `true` — or the input ends
    /// first (full decompression). The point is the *read*: it touches the file
    /// only as far into the compressed stream as the requested output prefix
    /// needs, so on a network volume it never reads the tail. (The in-memory
    /// `gunzip(_:maxOutputBytes:)` above can't do this — `Data(contentsOf:)` on a
    /// network mount reads every byte before inflate runs, because `.mappedIfSafe`
    /// won't map a remote volume.)
    ///
    /// `hasEnough` is re-evaluated after each inflate step against the cumulative
    /// output; it returns `false` until the caller can compute its bound (e.g.
    /// once the header is present). When it never becomes `true`, the whole stream
    /// is decompressed and the output is byte-identical to `gunzip(_:)`.
    static func gunzip(
        from handle: FileHandle,
        inputChunkBytes: Int = 1 << 18,
        hasEnough: (Foundation.Data) -> Bool
    ) throws -> Foundation.Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw MIQError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        var output = Foundation.Data()
        var outChunk = [UInt8](repeating: 0, count: inputChunkBytes)
        let outCapacity = outChunk.count
        var done = false
        var sawStreamEnd = false

        while !done {
            guard let input = try handle.read(upToCount: inputChunkBytes), !input.isEmpty else {
                break // compressed input exhausted before `hasEnough` — full stream
            }
            try input.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) in
                guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress else {
                    throw MIQError.decompressionFailed
                }
                stream.next_in = UnsafeMutablePointer(mutating: inBase)
                stream.avail_in = UInt32(input.count)
                while stream.avail_in > 0 {
                    let ret: Int32 = outChunk.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> Int32 in
                        guard let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress else {
                            return Z_MEM_ERROR
                        }
                        stream.next_out = outBase
                        stream.avail_out = UInt32(outCapacity)
                        let r = inflate(&stream, Z_NO_FLUSH)
                        let produced = outCapacity - Int(stream.avail_out)
                        if produced > 0 { output.append(outBase, count: produced) }
                        return r
                    }
                    if ret == Z_STREAM_END { sawStreamEnd = true; done = true; break }
                    if ret == Z_BUF_ERROR { break } // no progress possible — need more input
                    guard ret == Z_OK else { throw MIQError.decompressionFailed }
                    if hasEnough(output) { done = true; break }
                }
            }
            if !done && hasEnough(output) { done = true }
        }

        // A bounded early stop (`hasEnough`) is a deliberate success. Only a stream
        // that ran dry without ever ending *and* without satisfying the bound is a
        // real failure — that's a truncated/corrupt member.
        guard done || sawStreamEnd else {
            throw MIQError.decompressionFailed
        }
        return output
    }

    static func uint16(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> UInt16 {
        let base = data.startIndex + offset
        let b0 = UInt16(data[base])
        let b1 = UInt16(data[base + 1])
        if littleEndian {
            return b0 | (b1 << 8)
        }
        return (b0 << 8) | b1
    }

    static func uint32(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> UInt32 {
        let base = data.startIndex + offset
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        if littleEndian {
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    static func uint64(_ data: Foundation.Data, _ offset: Int, littleEndian: Bool) -> UInt64 {
        let base = data.startIndex + offset
        let b0 = UInt64(data[base])
        let b1 = UInt64(data[base + 1])
        let b2 = UInt64(data[base + 2])
        let b3 = UInt64(data[base + 3])
        let b4 = UInt64(data[base + 4])
        let b5 = UInt64(data[base + 5])
        let b6 = UInt64(data[base + 6])
        let b7 = UInt64(data[base + 7])
        if littleEndian {
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)
        }
        return (b0 << 56) | (b1 << 48) | (b2 << 40) | (b3 << 32) | (b4 << 24) | (b5 << 16) | (b6 << 8) | b7
    }
}