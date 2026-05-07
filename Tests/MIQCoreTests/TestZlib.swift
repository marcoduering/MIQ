import Foundation
import zlib

enum TestZlib {
    static func gzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_BEST_SPEED,
            Z_DEFLATED,
            16 + MAX_WBITS,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw NSError(domain: "TestZlib", code: Int(initStatus))
        }

        defer {
            deflateEnd(&stream)
        }

        var output = Data()
        let chunkSize = 64 * 1024
        var status: Int32 = Z_OK

        status = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Int32(Z_DATA_ERROR)
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = UInt32(rawBuffer.count)

            var localStatus: Int32 = Z_OK
            var outBuffer = [UInt8](repeating: 0, count: chunkSize)

            repeat {
                localStatus = outBuffer.withUnsafeMutableBytes { outRawBuffer in
                    guard let outBaseAddress = outRawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        return Int32(Z_MEM_ERROR)
                    }

                    stream.next_out = outBaseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let s = deflate(&stream, Z_FINISH)

                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        output.append(outBaseAddress, count: produced)
                    }

                    return s
                }

                if localStatus == Z_STREAM_END {
                    return localStatus
                }
            } while localStatus == Z_OK

            return localStatus
        }

        guard status == Z_STREAM_END else {
            throw NSError(domain: "TestZlib", code: Int(status))
        }

        return output
    }
}
