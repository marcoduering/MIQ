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

    static func isLikelyGzip(_ data: Foundation.Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }
        return data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
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

        // Gzip trailer: last 4 bytes = ISIZE (uncompressed size mod 2^32, little-endian).
        // Use it to pre-allocate the exact output buffer and decompress in one inflate call.
        let isize = data.withUnsafeBytes { bytes -> UInt32 in
            bytes.loadUnaligned(fromByteOffset: data.count - 4, as: UInt32.self)
        }.littleEndian
        guard isize > 0 else {
            throw MIQError.decompressionFailed
        }

        var output = Data(count: Int(isize))
        let result = data.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf -> Int32 in
                guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress,
                      let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_DATA_ERROR
                }
                stream.next_in = UnsafeMutablePointer(mutating: inBase)
                stream.avail_in = UInt32(data.count)
                stream.next_out = outBase
                stream.avail_out = isize
                return inflate(&stream, Z_FINISH)
            }
        }

        guard result == Z_STREAM_END else {
            throw MIQError.decompressionFailed
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
        guard isize > 0 else {
            throw MIQError.decompressionFailed
        }

        // Never allocate (or produce) more than the stream actually holds.
        let cap = Swift.min(Int(isize), maxOutputBytes)
        var output = Data(count: cap)
        var produced = 0
        let status: Int32 = data.withUnsafeBytes { inBuf -> Int32 in
            output.withUnsafeMutableBytes { outBuf -> Int32 in
                guard let inBase = inBuf.bindMemory(to: Bytef.self).baseAddress,
                      let outBase = outBuf.bindMemory(to: Bytef.self).baseAddress else {
                    return Z_DATA_ERROR
                }
                stream.next_in = UnsafeMutablePointer(mutating: inBase)
                stream.avail_in = UInt32(data.count)
                var ret: Int32 = Z_OK
                while produced < cap {
                    stream.next_out = outBase + produced
                    stream.avail_out = UInt32(cap - produced)
                    ret = inflate(&stream, Z_NO_FLUSH)
                    produced = cap - Int(stream.avail_out)
                    if ret != Z_OK { break }   // Z_STREAM_END, Z_BUF_ERROR, or hard error
                }
                return ret
            }
        }

        // Success: the whole stream decompressed, OR we filled the requested cap
        // (a deliberate early stop). Z_BUF_ERROR with a filled cap is expected —
        // it means "no output space left", which is exactly why we stopped.
        guard status == Z_STREAM_END || produced == cap else {
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