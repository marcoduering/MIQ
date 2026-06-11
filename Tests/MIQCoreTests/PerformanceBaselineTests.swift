import Accelerate
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

    // MARK: - RGBA bridge expansion A/B

    /// Times the SliceImage→RGBA expansion that runs on every interactive
    /// render. The optimization replaced the legacy bridge path (RGBA `[UInt8]`
    /// array build + a second full copy via `Data(array)` for the
    /// CGDataProvider, both on the MainActor) with the single-pass
    /// `rgbaBitmap()` that runs inside the detached render task. Byte-identical
    /// output is asserted before timing — the printed speedup is the per-plane
    /// conversion cost; the structural win (none of it on the main thread
    /// anymore) comes on top.
    @Test(.enabled(if: PerformanceBaselineTests.perfEnabled))
    func rgbaBridgeExpansion() throws {
        let side = Self.maxDimension
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        let gray = SliceImage.grayscale(GrayscaleImage(
            width: side, height: side, pixels: (0..<(side * side)).map { _ in next() }
        ))
        let rgb = SliceImage.rgb(RGBImage(
            width: side, height: side, pixels: (0..<(side * side * 3)).map { _ in next() }
        ))

        // Correctness gate — timings are meaningless if the bytes differ.
        #expect(try #require(gray.rgbaBitmap()).pixels == RGBABitmapTests.legacyExpansion(gray))
        #expect(try #require(rgb.rgbaBitmap()).pixels == RGBABitmapTests.legacyExpansion(rgb))

        let grayNew = Self.measure(iterations: 50) { _ = gray.rgbaBitmap() }
        let grayOld = Self.measure(iterations: 50) { _ = RGBABitmapTests.legacyExpansion(gray) }
        let rgbNew = Self.measure(iterations: 50) { _ = rgb.rgbaBitmap() }
        let rgbOld = Self.measure(iterations: 50) { _ = RGBABitmapTests.legacyExpansion(rgb) }

        print("")
        print("=== RGBA bridge expansion A/B (\(side)x\(side), per plane) ===")
        print(Self.row2("path", "median ms (min)", ""))
        print(Self.row2("gray legacy (2-copy)", Self.fmt(grayOld), ""))
        print(Self.row2("gray rgbaBitmap()", Self.fmt(grayNew),
                        String(format: "%.2fx", grayOld.medianMs / max(grayNew.medianMs, 0.0001))))
        print(Self.row2("rgb  legacy (2-copy)", Self.fmt(rgbOld), ""))
        print(Self.row2("rgb  rgbaBitmap()", Self.fmt(rgbNew),
                        String(format: "%.2fx", rgbOld.medianMs / max(rgbNew.medianMs, 0.0001))))
        print("")
    }

    // MARK: - Window percentile sort A/B

    /// Times the in-place sort `IntensityWindow.bounds` runs to find percentile
    /// window bounds — the dominant CPU stage of cold load after gunzip, and the
    /// per-step cost in per-volume windowing mode. The optimization swapped
    /// `Array.sort()` for Accelerate's `vDSP_vsort`; both sort the same finite
    /// multiset, so `bounds` output is bit-identical (asserted in
    /// `IntensityWindowSortTests`). Reports the speedup at slice scale.
    @Test(.enabled(if: PerformanceBaselineTests.perfEnabled))
    func windowPercentileSort() {
        // One in-plane slice's worth of voxels (the pooled center-slice buffer is
        // ~3× this; the per-slice reslice window is exactly this).
        let count = Self.maxDimension * Self.maxDimension
        var seed: UInt64 = 0x123456789ABCDEF
        func nextFloat() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) * 4000 - 2000
        }
        let source = (0..<count).map { _ in nextFloat() }

        let vdspMs = Self.measure(iterations: 30) {
            var buf = source
            buf.withUnsafeMutableBufferPointer { p in
                vDSP_vsort(p.baseAddress!, vDSP_Length(p.count), 1)
            }
            Self.blackHole(buf)
        }
        let swiftMs = Self.measure(iterations: 30) {
            var buf = source
            buf.sort()
            Self.blackHole(buf)
        }

        print("")
        print("=== Window percentile sort A/B (\(count) floats = \(Self.maxDimension)² slice) ===")
        print(Self.row2("path", "median ms (min)", ""))
        print(Self.row2("Array.sort() (old)", Self.fmt(swiftMs), ""))
        print(Self.row2("vDSP_vsort (new)", Self.fmt(vdspMs),
                        String(format: "%.2fx", swiftMs.medianMs / max(vdspMs.medianMs, 0.0001))))
        print("")
    }

    @inline(never)
    private static func blackHole(_ buf: [Float]) {
        // Prevent the optimizer from eliding the sort: touch one element.
        if buf.isEmpty { fatalError("unreachable") }
    }

    // MARK: - Nearest-neighbor resample A/B

    /// Times `nearestNeighborResample` (the FOV-aware preview resample that runs
    /// on every cold slice and every scroll-step reslice) against the previous
    /// per-pixel scalar implementation. The rewrite hoists a source-column LUT,
    /// lifts the row index out of the inner loop, drops bounds checks, and
    /// special-cases 1/3 channels; output is byte-identical (asserted in
    /// `NearestNeighborResampleTests`).
    @Test(.enabled(if: PerformanceBaselineTests.perfEnabled))
    func resampleDownscale() {
        // A 600² source downscaled to 512² — representative of a hi-res slice
        // resampled into the preview's max dimension.
        let w = 600, h = 600, tw = 512, th = 512
        var seed: UInt64 = 0xFEEDFACECAFEF00D
        func nextByte() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }

        for (channels, label) in [(1, "gray"), (3, "rgb ")] {
            let pixels = (0..<(w * h * channels)).map { _ in nextByte() }
            let newMs = Self.measure(iterations: 30) {
                _ = nearestNeighborResample(pixels: pixels, width: w, height: h,
                                            channels: channels, targetWidth: tw, targetHeight: th)
            }
            let oldMs = Self.measure(iterations: 30) {
                _ = Self.scalarResample(pixels: pixels, width: w, height: h,
                                        channels: channels, targetWidth: tw, targetHeight: th)
            }
            if channels == 1 {
                print("")
                print("=== Nearest-neighbor resample A/B (\(w)²→\(tw)², per plane) ===")
                print(Self.row2("path", "median ms (min)", ""))
            }
            print(Self.row2("\(label) scalar (old)", Self.fmt(oldMs), ""))
            print(Self.row2("\(label) hoisted (new)", Self.fmt(newMs),
                            String(format: "%.2fx", oldMs.medianMs / max(newMs.medianMs, 0.0001))))
        }
        print("")
    }

    /// The pre-optimization scalar resample, verbatim — the A/B reference.
    private static func scalarResample(
        pixels: [UInt8], width: Int, height: Int, channels: Int,
        targetWidth: Int, targetHeight: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: targetWidth * targetHeight * channels)
        for ny in 0..<targetHeight {
            for nx in 0..<targetWidth {
                let sxIdx = min(width - 1, Int(Float(nx) * Float(width) / Float(targetWidth)))
                let syIdx = min(height - 1, Int(Float(ny) * Float(height) / Float(targetHeight)))
                let srcBase = (syIdx * width + sxIdx) * channels
                let dstBase = (ny * targetWidth + nx) * channels
                for c in 0..<channels {
                    out[dstBase + c] = pixels[srcBase + c]
                }
            }
        }
        return out
    }

    // MARK: - Real corpus cold-load profile

    /// One stage's median ms. `nil` = not applicable (e.g. gunzip for an
    /// uncompressed file, ⌥-volume reslice for a 3D volume).
    private struct Stages: Codable {
        var previewTotal: Double?       // headline: parse(url) + centerPreview, min-based & stable
        var coldParsePreview: Double?   // single 1× cold run — real-world cross-check, noisy
        var mmapRead: Double?
        var parseHeader: Double?
        var gunzipFull: Double?
        var parseEndToEnd: Double?
        var fixedCenterWindow: Double?
        var centerPreview: Double?
        var reslice: Double?
        var volumeReslice: Double?
    }

    private struct CaseResult: Codable {
        var label: String
        var file: String
        var sizeMB: Int
        var dims: String
        var datatype: String
        var strides: String
        var payloadMB: Int
        var spans: [String]
        var stages: Stages
    }

    private struct CorpusReport: Codable {
        var host: String
        var generatedAt: String
        var cases: [CaseResult]
    }

    /// Path to a gitignored corpus list (`label<TAB>/abs/path`, `#` comments).
    private static let corpusPath = ProcessInfo.processInfo.environment["MIQ_PERF_CORPUS"]

    /// Profiles every file in the corpus through the *actual Quick Look cold
    /// path*, stage by stage, prints layout/stride diagnostics, and — when a
    /// baseline JSON exists — prints the per-stage delta vs history with a
    /// regression flag. Writes machine-readable results when `MIQ_PERF_JSON` is
    /// set. Driven by `scripts/perf/profile.sh`; see that script for usage.
    @Test(.enabled(if: PerformanceBaselineTests.corpusPath != nil))
    func corpusProfile() throws {
        let listURL = URL(fileURLWithPath: try #require(Self.corpusPath))
        let entries = try Self.readCorpus(listURL)

        let threshold = Double(ProcessInfo.processInfo.environment["MIQ_PERF_THRESHOLD"] ?? "") ?? 1.20
        let baseline = (ProcessInfo.processInfo.environment["MIQ_PERF_BASELINE"])
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode(CorpusReport.self, from: $0) }

        print("")
        print("=== MIQ corpus cold-load profile ===")
        let host = ProcessInfo.processInfo.operatingSystemVersionString
        print("host: \(host)")
        if let baseline {
            print("baseline: \(baseline.generatedAt) on \(baseline.host)")
            if baseline.host != host {
                print("⚠️  baseline host differs — absolute deltas are machine-dependent, read trends not points")
            }
        } else {
            print("baseline: none (run with --update-baseline to seed one)")
        }
        print("regression flag at > \(String(format: "%.0f%%", (threshold - 1) * 100)) slower than baseline")

        var results: [CaseResult] = []
        for entry in entries {
            guard let result = Self.profile(label: entry.label, path: entry.path) else {
                print("\n[skip] \(entry.label) — \(entry.path) not found / unparseable")
                continue
            }
            results.append(result)
            let prior = baseline?.cases.first { $0.label == entry.label }
            Self.printCase(result, baseline: prior, threshold: threshold)
        }

        let report = CorpusReport(
            host: host,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            cases: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(report)

        if let out = ProcessInfo.processInfo.environment["MIQ_PERF_JSON"] {
            try json.write(to: URL(fileURLWithPath: out))
            print("\nresults written: \(out)")
        }
        if ProcessInfo.processInfo.environment["MIQ_PERF_UPDATE_BASELINE"] == "1",
           let base = ProcessInfo.processInfo.environment["MIQ_PERF_BASELINE"] {
            try json.write(to: URL(fileURLWithPath: base))
            print("baseline updated: \(base)")
        }
        print("")
    }

    /// Comma-separated ad-hoc list (no baseline / JSON). Kept for one-off probing
    /// outside the curated corpus.
    private static let mifPaths = ProcessInfo.processInfo.environment["MIQ_PERF_MIF"]

    @Test(.enabled(if: PerformanceBaselineTests.mifPaths != nil))
    func realMifProfile() throws {
        let paths = try #require(Self.mifPaths)
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        print("")
        print("=== Ad-hoc MIF profile ===  host: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        for path in paths {
            if let r = Self.profile(label: URL(fileURLWithPath: path).lastPathComponent, path: path) {
                Self.printCase(r, baseline: nil, threshold: 1.20)
            } else {
                print("\n[skip] \(path) — not found")
            }
        }
        print("")
    }

    // MARK: - Profiling core (shared)

    private static func readCorpus(_ url: URL) throws -> [(label: String, path: String)] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Split on the first run of whitespace: `label   /abs/path`.
            guard let sep = line.rangeOfCharacter(from: .whitespaces) else { continue }
            let label = String(line[..<sep.lowerBound])
            let path = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, !path.isEmpty { out.append((label, path)) }
        }
        return out
    }

    /// Runs every cold-path stage for one file. Returns `nil` if the file is
    /// missing or fails to parse (so the corpus run continues).
    private static func profile(label: String, path: String) -> CaseResult? {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let image = try? MIQParser().parse(url: url) else {
            return nil
        }

        // Cold cost: a fresh QL process does parse + centerPreview with nothing
        // cached. warmup:0 / iterations:1 captures the first-touch (page-fault /
        // gunzip) cost the user actually waits for.
        let coldDur = ContinuousClock().measure {
            guard let img = try? MIQParser().parse(url: url) else { return }
            _ = MIQVolume(image: img).centerPreview(volumeIndex: 0, maxDimension: maxDimension, options: options)
        }

        let readMs = measure(iterations: 3) { _ = try? Data(contentsOf: url, options: [.mappedIfSafe]) }
        let headerMs = measure(iterations: 3) { _ = try? MIQParser().parseHeader(url: url) }
        let isGz = url.pathExtension.lowercased() == "gz"
        var gunzipMs: (minMs: Double, medianMs: Double)?
        if isGz, let rawData = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            gunzipMs = measure(iterations: 3) { _ = try? MIQBinaryReader.gunzip(rawData) }
        }
        let parseMs = measure(iterations: 3) { _ = try? MIQParser().parse(url: url) }

        let volume = MIQVolume(image: image)
        let h = image.header
        let windowMs = measure(iterations: 3) { _ = volume.fixedCenterWindow(volumeIndex: 0, options: options) }
        let previewMs = measure(iterations: 3) {
            _ = volume.centerPreview(volumeIndex: 0, maxDimension: maxDimension, options: options)
        }
        let bounds = volume.fixedCenterWindow(volumeIndex: 0, options: options)
        let cursor = volume.centerCursor()
        let resliceMs = measure(iterations: 5) {
            let idx = volume.sliceIndex(for: .axial, cursor: cursor, options: options) + 1
            _ = volume.slice(plane: .axial, index: idx, volumeIndex: 0,
                             maxDimension: maxDimension, options: options, windowBounds: bounds)
        }
        var volScrollMs: (minMs: Double, medianMs: Double)?
        if volume.volumes > 1 {
            volScrollMs = measure(iterations: 5) {
                let idx = volume.sliceIndex(for: .axial, cursor: cursor, options: options)
                _ = volume.slice(plane: .axial, index: idx, volumeIndex: 1,
                                 maxDimension: maxDimension, options: options, windowBounds: bounds)
            }
        }

        let bpv = h.datatype.bytesPerVoxel
        let payloadBytes = (h.width * h.height * h.depth * max(1, h.volumes)) * bpv
        let spans = SlicePlane.allCases.map {
            spanLine(plane: $0, volume: volume, bpv: bpv, payloadBytes: payloadBytes)
        }

        return CaseResult(
            label: label,
            file: url.lastPathComponent,
            sizeMB: Int((Double(size) / 1_048_576).rounded()),
            dims: "\(h.width)x\(h.height)x\(h.depth) vol=\(h.volumes)",
            datatype: "\(h.datatype) (\(bpv)B)",
            strides: image.payloadElementStrides.map { "\($0)" } ?? "linear (no strides)",
            payloadMB: Int((Double(payloadBytes) / 1_048_576).rounded()),
            spans: spans,
            // Compare on MIN, not median: the least-contended sample is the
            // stablest cross-run statistic for microbenchmarks (median still
            // drifts with background load and produces false regressions). COLD
            // is a single 1× run by design — inherently noisy, never flagged.
            stages: Stages(
                // The end-to-end cold MIQCore cost: decompress+parse then the
                // 3-plane center render. Sum of mins = stable, comparable total
                // (vs the 1× coldParsePreview which page-cache state makes noisy).
                previewTotal: parseMs.minMs + previewMs.minMs,
                coldParsePreview: ms(coldDur),
                mmapRead: readMs.minMs,
                parseHeader: headerMs.minMs,
                gunzipFull: gunzipMs?.minMs,
                parseEndToEnd: parseMs.minMs,
                fixedCenterWindow: windowMs.minMs,
                centerPreview: previewMs.minMs,
                reslice: resliceMs.minMs,
                volumeReslice: volScrollMs?.minMs
            )
        )
    }

    private static func printCase(_ r: CaseResult, baseline: CaseResult?, threshold: Double) {
        print("")
        print("\(r.label)  —  \(r.file)  (\(r.sizeMB) MB on disk)")
        print("dim: \(r.dims)  datatype: \(r.datatype)")
        print("strides [x,y,z,t]: \(r.strides)  payload: \(r.payloadMB) MB")
        for s in r.spans { print("  \(s)") }
        print(String(repeating: "-", count: 72))
        print(Self.row3("stage", "min ms", "vs baseline"))

        func line(_ name: String, _ cur: Double?, _ base: Double?, flag: Bool = true) {
            guard let cur else { return }
            let curStr = String(format: "%.1f", cur)
            var cmp = ""
            if let base, base > 0 {
                let ratio = cur / base
                let pct = (ratio - 1) * 100
                // Flag only when meaningful: the stage is flaggable (COLD is a 1×
                // run, never flagged) and both sides clear ~1 ms (below that,
                // timing jitter dominates the ratio — show the delta unflagged so
                // the tool doesn't cry wolf every release).
                let stable = flag && base >= 1.0 && cur >= 1.0
                let mark = !stable ? "" : (ratio > threshold ? " ⚠️ REGRESSION" : (ratio < 0.8 ? " ✅ faster" : ""))
                cmp = String(format: "%.1f → %.1f (%+.0f%%)%@", base, cur, pct, mark)
            } else if base == nil {
                cmp = "—"
            }
            print(Self.row3(name, curStr, cmp))
        }
        let b = baseline?.stages
        line("TOTAL parse+preview", r.stages.previewTotal, b?.previewTotal)
        print(String(repeating: "·", count: 72))
        line("  COLD 1× (real-world)", r.stages.coldParsePreview, b?.coldParsePreview, flag: false)
        line("  mmap read", r.stages.mmapRead, b?.mmapRead)
        line("  parseHeader(url)", r.stages.parseHeader, b?.parseHeader)
        line("  gunzip (zlib, full)", r.stages.gunzipFull, b?.gunzipFull)
        line("  parse(url) end-to-end", r.stages.parseEndToEnd, b?.parseEndToEnd)
        line("  fixedCenterWindow", r.stages.fixedCenterWindow, b?.fixedCenterWindow)
        line("  centerPreview", r.stages.centerPreview, b?.centerPreview)
        line("  reslice (x/y/z scroll)", r.stages.reslice, b?.reslice)
        line("  reslice (⌥ volume scroll)", r.stages.volumeReslice, b?.volumeReslice)
        print(String(repeating: "-", count: 72))
    }

    private static func row3(_ a: String, _ b: String, _ c: String) -> String {
        let wa = 27, wb = 11
        let pa = a.count >= wa ? a : a + String(repeating: " ", count: wa - a.count)
        let pb = b.count >= wb ? b : b + String(repeating: " ", count: wb - b.count)
        return pa + " " + pb + " " + c
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
