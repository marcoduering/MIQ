import Compression
import Foundation
import Testing
import zlib
@testable import MIQCore

/// Reproducible baseline measurements for the MIQCore hot path, so the gains
/// (or regressions) from slicing/windowing optimizations are verifiable rather
/// than assumed.
///
/// Skipped by default. Run explicitly with:
///
///     cd /tmp && MIQ_PERF=1 swift test --package-path /Users/mduering/Git/MIQ \
///       --scratch-path /tmp/miq-build --filter PerformanceBaseline
///
/// Each stage is timed in isolation so we can see where time actually goes:
///   parse(mmap)  — Data(contentsOf:.mappedIfSafe) + header parse (payload is zero-copy)
///   parse(gz)    — same, but the file is gzipped → includes full gunzip
///   window       — volume.fixedCenterWindow (decode 3 center slices + pool + sort)
///   firstFrame   — what MIQPreviewModel does on a cold load: window THEN render all
///                  3 center planes with shared bounds (note: center slices are
///                  decoded twice today — this baseline deliberately captures that)
///   reslice      — one off-center plane with fixed bounds (per scroll-step cost)
struct PerformanceBaselineTests {

    private static let perfEnabled = ProcessInfo.processInfo.environment["MIQ_PERF"] == "1"

    private static let options = RenderingOptions(
        lowerPercentile: MIQConfig.Defaults.windowLowerPercentile,
        upperPercentile: MIQConfig.Defaults.windowUpperPercentile,
        orientation: .stored
    )
    private static let maxDimension = 512

    private struct Case {
        let name: String
        let width: Int
        let height: Int
        let depth: Int
        let datatype: MIQDatatype
    }

    private static let cases: [Case] = [
        Case(name: "uint8  256^3   (typical floor)",  width: 256, height: 256, depth: 256, datatype: .uint8),
        Case(name: "int16  256^3   (structural MRI)", width: 256, height: 256, depth: 256, datatype: .int16),
        Case(name: "float32 256^3  (param maps)",     width: 256, height: 256, depth: 256, datatype: .float32),
        Case(name: "int16  512x512x256 (hi-res)",     width: 512, height: 512, depth: 256, datatype: .int16),
    ]

    @Test(.enabled(if: PerformanceBaselineTests.perfEnabled))
    func baseline() throws {
        print("")
        print("=== MIQCore performance baseline ===")
        print("host: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print(Self.row("case", "fileMB", "parse", "parseGz", "window", "firstFrame", "preview", "reslice"))
        print(String(repeating: "-", count: 110))

        for c in Self.cases {
            let raw = Self.makeNifti(width: c.width, height: c.height, depth: c.depth, datatype: c.datatype)
            let gz = try TestZlib.gzip(raw)

            let plainURL = Self.tempURL(suffix: ".nii")
            let gzURL = Self.tempURL(suffix: ".nii.gz")
            try raw.write(to: plainURL)
            try gz.write(to: gzURL)
            defer {
                try? FileManager.default.removeItem(at: plainURL)
                try? FileManager.default.removeItem(at: gzURL)
            }

            let parseMs = Self.measure(iterations: 5) {
                _ = try? MIQParser().parse(url: plainURL)
            }
            let parseGzMs = Self.measure(iterations: 3) {
                _ = try? MIQParser().parse(url: gzURL)
            }

            let image = try MIQParser().parse(url: plainURL)
            let volume = MIQVolume(image: image)

            let windowMs = Self.measure(iterations: 5) {
                _ = volume.fixedCenterWindow(volumeIndex: 0, options: Self.options)
            }
            let firstFrameMs = Self.measure(iterations: 5) {
                Self.renderFirstFrame(volume: volume)
            }
            let previewMs = Self.measure(iterations: 5) {
                _ = volume.centerPreview(volumeIndex: 0, maxDimension: Self.maxDimension, options: Self.options)
            }

            let bounds = volume.fixedCenterWindow(volumeIndex: 0, options: Self.options)
            let cursor = volume.centerCursor()
            let resliceMs = Self.measure(iterations: 10) {
                let idx = volume.sliceIndex(for: .axial, cursor: cursor, options: Self.options) + 1
                _ = volume.slice(
                    plane: .axial, index: idx, volumeIndex: 0,
                    maxDimension: Self.maxDimension, options: Self.options, windowBounds: bounds
                )
            }

            let fileMB = String(format: "%.1f", Double(raw.count) / (1024 * 1024))
            print(Self.row(
                c.name, fileMB,
                Self.fmt(parseMs), Self.fmt(parseGzMs), Self.fmt(windowMs),
                Self.fmt(firstFrameMs), Self.fmt(previewMs), Self.fmt(resliceMs)
            ))
        }
        print(String(repeating: "-", count: 110))
        print("median ms (min in parens).")
        print("firstFrame = old path (fixedCenterWindow + 3-plane render, double decode).")
        print("preview    = new centerPreview (single decode). gunzip cost ≈ parseGz − parse.")
        print("")
    }

    // MARK: - Real-file gunzip A/B

    private static let realFilePath = ProcessInfo.processInfo.environment["MIQ_PERF_FILE"]

    /// Isolates gunzip on a real, low-redundancy `.nii.gz` (e.g. 4D DWI) — the
    /// case the synthetic matrix understates because its payload is trivially
    /// compressible. A/Bs the current zlib `inflate` against Apple's
    /// dependency-free `libcompression` raw-DEFLATE, validating byte-identical
    /// output before reporting timings.
    ///
    ///     MIQ_PERF_FILE=/path/to/file.nii.gz swift test -c release \
    ///       --package-path … --scratch-path … --filter realFileGunzip
    @Test(.enabled(if: PerformanceBaselineTests.realFilePath != nil))
    func realFileGunzip() throws {
        let path = try #require(Self.realFilePath)
        let url = URL(fileURLWithPath: path)

        let readMs = Self.measure(iterations: 3) {
            _ = try? Data(contentsOf: url, options: [.mappedIfSafe])
        }
        let raw = try Data(contentsOf: url, options: [.mappedIfSafe])
        #expect(MIQBinaryReader.isLikelyGzip(raw))

        // Reference: current production path.
        let zlibOut = try MIQBinaryReader.gunzip(raw)
        let appleOut = try #require(Self.appleGunzip(raw), "libcompression path failed to produce output")

        // Correctness gate — timings are meaningless if the bytes differ.
        #expect(zlibOut.count == appleOut.count)
        #expect(zlibOut == appleOut)

        let zlibMs = Self.measure(iterations: 3) { _ = try? MIQBinaryReader.gunzip(raw) }
        let appleMs = Self.measure(iterations: 3) { _ = Self.appleGunzip(raw) }
        let parseMs = Self.measure(iterations: 3) { _ = try? MIQParser().parse(url: url) }

        let compMB = Double(raw.count) / (1024 * 1024)
        let outMB = Double(zlibOut.count) / (1024 * 1024)
        func tput(_ r: (minMs: Double, medianMs: Double)) -> String {
            String(format: "%.0f MB/s", outMB / (r.medianMs / 1000))
        }

        print("")
        print("=== Real-file gunzip A/B ===")
        print("file: \(url.lastPathComponent)")
        print(String(format: "compressed: %.1f MB   uncompressed: %.1f MB   ratio: %.2fx",
                     compMB, outMB, outMB / compMB))
        print("byte-identical zlib vs libcompression: \(zlibOut == appleOut)")
        print(String(repeating: "-", count: 64))
        print(Self.row2("stage", "median ms (min)", "throughput"))
        print(Self.row2("mmap read", Self.fmt(readMs), ""))
        print(Self.row2("gunzip (zlib, current)", Self.fmt(zlibMs), tput(zlibMs)))
        print(Self.row2("gunzip (libcompression)", Self.fmt(appleMs), tput(appleMs)))
        print(Self.row2("parse(url) end-to-end", Self.fmt(parseMs), ""))
        print(String(repeating: "-", count: 64))
        let speedup = zlibMs.medianMs / max(appleMs.medianMs, 0.0001)
        print(String(format: "libcompression speedup vs zlib: %.2fx", speedup))
        print("")
    }

    /// gzip → raw DEFLATE via Apple's Compression framework. Strips the gzip
    /// wrapper (RFC 1952): 10-byte fixed header + optional FEXTRA/FNAME/FCOMMENT/
    /// FHCRC fields (FLG bits) + 8-byte trailer; the remaining body is the raw
    /// DEFLATE stream that `COMPRESSION_ZLIB` decodes. Output size = trailer ISIZE.
    private static func appleGunzip(_ data: Data) -> Data? {
        guard data.count >= 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return nil
        }
        let flg = data[data.startIndex + 3]
        var headerLen = 10
        func u8(_ i: Int) -> Int { Int(data[data.startIndex + i]) }
        if flg & 0x04 != 0 { // FEXTRA
            guard data.count >= data.startIndex + headerLen + 2 else { return nil }
            let xlen = u8(headerLen) | (u8(headerLen + 1) << 8)
            headerLen += 2 + xlen
        }
        if flg & 0x08 != 0 { // FNAME (zero-terminated)
            while headerLen < data.count, u8(headerLen) != 0 { headerLen += 1 }
            headerLen += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT (zero-terminated)
            while headerLen < data.count, u8(headerLen) != 0 { headerLen += 1 }
            headerLen += 1
        }
        if flg & 0x02 != 0 { headerLen += 2 } // FHCRC
        guard data.count > headerLen + 8 else { return nil }

        let isize = data.withUnsafeBytes { bytes -> UInt32 in
            bytes.loadUnaligned(fromByteOffset: data.count - 4, as: UInt32.self)
        }.littleEndian
        guard isize > 0 else { return nil }

        let deflateCount = data.count - headerLen - 8
        var out = Data(count: Int(isize))
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // Feed the DEFLATE body in place (no copy): base + headerLen.
                return compression_decode_buffer(d, Int(isize), s + headerLen, deflateCount, nil, COMPRESSION_ZLIB)
            }
        }
        return written == Int(isize) ? out : nil
    }

    // MARK: - Real MIF cold-load profile

    /// Comma-separated list of real `.mif` / `.mif.gz` files to profile.
    private static let mifPaths = ProcessInfo.processInfo.environment["MIQ_PERF_MIF"]

    /// Profiles the *actual Quick Look cold path* for real MIF files, stage by
    /// stage, and prints the layout-derived strides + per-center-slice byte span
    /// so the bottleneck is visible rather than guessed.
    ///
    ///     MIQ_PERF_MIF="/a/dwi.mif,/a/dwi.mif.gz,/a/test.mif" swift test -c release \
    ///       --package-path … --scratch-path … --filter realMifProfile
    @Test(.enabled(if: PerformanceBaselineTests.mifPaths != nil))
    func realMifProfile() throws {
        let paths = try #require(Self.mifPaths)
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        print("")
        print("=== Real MIF cold-load profile ===")
        print("host: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int else {
                print("\n[skip] \(path) — not found"); continue
            }

            // Cold cost: a fresh QL process does parse + centerPreview with nothing
            // cached. warmup:0 / iterations:1 captures the first-touch (page fault /
            // gunzip) cost the user actually waits for.
            let coldClock = ContinuousClock()
            let coldDur = coldClock.measure {
                guard let img = try? MIQParser().parse(url: url) else { return }
                _ = MIQVolume(image: img).centerPreview(volumeIndex: 0, maxDimension: Self.maxDimension, options: Self.options)
            }

            let readMs = Self.measure(iterations: 3) {
                _ = try? Data(contentsOf: url, options: [.mappedIfSafe])
            }
            let headerMs = Self.measure(iterations: 3) {
                _ = try? MIQParser().parseHeader(url: url)
            }
            let isGz = url.pathExtension.lowercased() == "gz"
            var gunzipMs: (minMs: Double, medianMs: Double)?
            if isGz, let raw = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                gunzipMs = Self.measure(iterations: 3) { _ = try? MIQBinaryReader.gunzip(raw) }
            }
            let parseMs = Self.measure(iterations: 3) { _ = try? MIQParser().parse(url: url) }

            let image = try MIQParser().parse(url: url)
            let volume = MIQVolume(image: image)
            let h = image.header

            let windowMs = Self.measure(iterations: 3) {
                _ = volume.fixedCenterWindow(volumeIndex: 0, options: Self.options)
            }
            let previewMs = Self.measure(iterations: 3) {
                _ = volume.centerPreview(volumeIndex: 0, maxDimension: Self.maxDimension, options: Self.options)
            }
            let bounds = volume.fixedCenterWindow(volumeIndex: 0, options: Self.options)
            let cursor = volume.centerCursor()
            let resliceMs = Self.measure(iterations: 5) {
                let idx = volume.sliceIndex(for: .axial, cursor: cursor, options: Self.options) + 1
                _ = volume.slice(plane: .axial, index: idx, volumeIndex: 0,
                                  maxDimension: Self.maxDimension, options: Self.options, windowBounds: bounds)
            }
            var volScrollMs: (minMs: Double, medianMs: Double)?
            if volume.volumes > 1 {
                volScrollMs = Self.measure(iterations: 5) {
                    let idx = volume.sliceIndex(for: .axial, cursor: cursor, options: Self.options)
                    _ = volume.slice(plane: .axial, index: idx, volumeIndex: 1,
                                     maxDimension: Self.maxDimension, options: Self.options, windowBounds: bounds)
                }
            }

            // Layout diagnostics: element strides and the byte span each center
            // slice walks. A span ≈ whole payload ⇒ no prefix optimization is
            // possible and uncompressed reads fault in the entire file.
            let strides = image.payloadElementStrides.map { "\($0)" } ?? "linear (no strides)"
            let bpv = h.datatype.bytesPerVoxel
            let payloadBytes = (h.width * h.height * h.depth * max(1, h.volumes)) * bpv

            print("")
            print("file: \(url.lastPathComponent)  (\(String(format: "%.0f", Double(size) / 1_048_576)) MB on disk)")
            print("dim: \(h.width)x\(h.height)x\(h.depth) vol=\(h.volumes)  datatype: \(h.datatype) (\(bpv)B)")
            print("payloadElementStrides [x,y,z,t]: \(strides)  payload: \(String(format: "%.0f", Double(payloadBytes) / 1_048_576)) MB")
            for plane in SlicePlane.allCases {
                print("  \(Self.spanLine(plane: plane, volume: volume, bpv: bpv, payloadBytes: payloadBytes))")
            }
            print(String(repeating: "-", count: 64))
            print(Self.row2("stage", "median ms (min)", ""))
            print(Self.row2("COLD parse+preview (1×)", String(format: "%.0f", Self.ms(coldDur)), "← user-perceived"))
            print(Self.row2("mmap read", Self.fmt(readMs), ""))
            print(Self.row2("parseHeader(url)", Self.fmt(headerMs), ""))
            if let gunzipMs { print(Self.row2("gunzip (zlib, full)", Self.fmt(gunzipMs), "")) }
            print(Self.row2("parse(url) end-to-end", Self.fmt(parseMs), ""))
            print(Self.row2("fixedCenterWindow", Self.fmt(windowMs), "3 center decodes + sort"))
            print(Self.row2("centerPreview", Self.fmt(previewMs), "cold render path"))
            print(Self.row2("reslice (x/y/z scroll)", Self.fmt(resliceMs), "1 off-center plane"))
            if let volScrollMs { print(Self.row2("reslice (⌥ volume scroll)", Self.fmt(volScrollMs), "vol 0→1")) }
            print(String(repeating: "-", count: 64))
        }
        print("")
    }

    /// Byte span (min..max payload byte) a single center slice touches, given the
    /// signed/abs element strides — the locality fingerprint of the layout.
    private static func spanLine(plane: SlicePlane, volume: MIQVolume, bpv: Int, payloadBytes: Int) -> String {
        let geo = volume.sliceGeometry(for: plane, options: options)
        let cursor = volume.centerCursor()
        let slice = cursor.coordinate(forAxis: geo.sliceAxis)
        var lo = Int.max, hi = Int.min
        let img = volume.image
        let stepW = max(1, geo.width / 32), stepH = max(1, geo.height / 32)
        var c = [0, 0, 0]
        c[geo.sliceAxis] = slice
        var row = 0
        while row < geo.height {
            var col = 0
            while col < geo.width {
                c[geo.horizontalAxis] = col
                c[geo.verticalAxis] = row
                let e = img.voxelElementIndex(x: c[0], y: c[1], z: c[2], t: 0) * bpv
                lo = Swift.min(lo, e); hi = Swift.max(hi, e + bpv)
                col += stepW
            }
            row += stepH
        }
        let spanMB = Double(hi - lo) / 1_048_576
        let pct = payloadBytes > 0 ? 100.0 * Double(hi - lo) / Double(payloadBytes) : 0
        return String(format: "%@ center: spans %.0f MB (%.0f%% of payload)",
                      "\(plane)".padding(toLength: 9, withPad: " ", startingAt: 0), spanMB, pct)
    }

    private static func row2(_ a: String, _ b: String, _ c: String) -> String {
        let wa = 26, wb = 18
        let pa = a.count >= wa ? a : a + String(repeating: " ", count: wa - a.count)
        let pb = b.count >= wb ? b : b + String(repeating: " ", count: wb - b.count)
        return pa + " " + pb + " " + c
    }

    // MARK: - Stage reproduction

    /// Mirrors MIQPreviewModel.loadPreviewData's cold path exactly, including the
    /// fact that the 3 center slices are decoded once for windowing and again for
    /// rendering. Optimization #2 targets exactly this duplication.
    private static func renderFirstFrame(volume: MIQVolume) {
        let bounds = volume.fixedCenterWindow(volumeIndex: 0, options: options)
        let cursor = volume.centerCursor()
        for plane in SlicePlane.allCases {
            let index = volume.sliceIndex(for: plane, cursor: cursor, options: options)
            _ = volume.slice(
                plane: plane, index: index, volumeIndex: 0,
                maxDimension: maxDimension, options: options, windowBounds: bounds
            )
        }
    }

    // MARK: - Timing

    private static func measure(iterations: Int, warmup: Int = 1, _ body: () -> Void) -> (minMs: Double, medianMs: Double) {
        for _ in 0..<warmup { body() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            let d = clock.measure { body() }
            samples.append(Self.ms(d))
        }
        samples.sort()
        return (samples.first ?? 0, samples[samples.count / 2])
    }

    private static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }

    private static func fmt(_ r: (minMs: Double, medianMs: Double)) -> String {
        String(format: "%.1f(%.1f)", r.medianMs, r.minMs)
    }

    private static func row(_ cols: String...) -> String {
        let widths = [30, 8, 12, 12, 12, 14, 12, 12]
        return cols.enumerated().map { i, s in
            let w = i < widths.count ? widths[i] : 12
            return s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }.joined(separator: " ")
    }

    // MARK: - Synthetic NIfTI-1

    private static func tempURL(suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("miq-perf-\(UUID().uuidString)\(suffix)")
    }

    /// Minimal valid NIfTI-1 (.nii) with a non-constant, finite payload so that
    /// windowing/percentile and slice decode do representative work. Offsets match
    /// `MIQParser.parseNifti1Header`. Built directly into one `Data` buffer to keep
    /// the harness's own footprint low for the 134 MB case.
    private static func makeNifti(width: Int, height: Int, depth: Int, datatype: MIQDatatype) -> Data {
        let voxOffset = 352
        let voxelCount = width * height * depth
        let payloadBytes = voxelCount * datatype.bytesPerVoxel
        var data = Data(count: voxOffset + payloadBytes)

        data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!

            func putI16(_ v: Int16, _ off: Int) {
                base.storeBytes(of: v.littleEndian, toByteOffset: off, as: Int16.self)
            }
            func putI32(_ v: Int32, _ off: Int) {
                base.storeBytes(of: v.littleEndian, toByteOffset: off, as: Int32.self)
            }
            func putF32(_ v: Float, _ off: Int) {
                base.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: off, as: UInt32.self)
            }

            putI32(348, 0)
            putI16(3, 40)
            putI16(Int16(width), 42)
            putI16(Int16(height), 44)
            putI16(Int16(depth), 46)
            putI16(1, 48)
            putI16(datatype.rawValue, 70)
            putI16(Int16(datatype.bytesPerVoxel * 8), 72)
            putF32(1, 76)   // pixdim[0] = qfac
            putF32(1, 80)   // pixdim[1]
            putF32(1, 84)   // pixdim[2]
            putF32(1, 88)   // pixdim[3]
            putF32(Float(voxOffset), 108)
            putF32(1, 112)  // scl_slope
            putF32(0, 116)  // scl_inter
            putI16(0, 252)  // qform_code
            putI16(0, 254)  // sform_code

            let p = base + voxOffset
            switch datatype {
            case .uint8, .int8, .rgb24, .rgba32:
                let bpv = datatype.bytesPerVoxel
                let bytes = p.bindMemory(to: UInt8.self, capacity: payloadBytes)
                for i in 0..<payloadBytes {
                    bytes[i] = UInt8((i &* 97 &+ (i / max(1, bpv)) &* 13) & 0xFF)
                }
            case .int16, .uint16:
                let vals = p.bindMemory(to: Int16.self, capacity: voxelCount)
                for i in 0..<voxelCount {
                    vals[i] = Int16(truncatingIfNeeded: (i &* 131 &+ 7) & 0x03FF).littleEndian
                }
            case .int32, .uint32:
                let vals = p.bindMemory(to: Int32.self, capacity: voxelCount)
                for i in 0..<voxelCount {
                    vals[i] = Int32(truncatingIfNeeded: (i &* 131 &+ 7) & 0x000FFFFF).littleEndian
                }
            case .float32:
                let vals = p.bindMemory(to: UInt32.self, capacity: voxelCount)
                for i in 0..<voxelCount {
                    let f = Float((i % 1000)) * 0.5 + 0.25
                    vals[i] = f.bitPattern.littleEndian
                }
            case .float64:
                let vals = p.bindMemory(to: UInt64.self, capacity: voxelCount)
                for i in 0..<voxelCount {
                    let d = Double((i % 1000)) * 0.5 + 0.25
                    vals[i] = d.bitPattern.littleEndian
                }
            }
        }
        return data
    }
}
