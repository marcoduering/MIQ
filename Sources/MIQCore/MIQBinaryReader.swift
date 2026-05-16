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