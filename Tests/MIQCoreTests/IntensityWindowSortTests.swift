import Foundation
import Testing
@testable import MIQCore

/// `IntensityWindow.bounds` switched its in-place sort from `Array.sort()` to
/// Accelerate's `vDSP_vsort`. The rendered preview must not change, so these
/// pin the windowed output bit-identical to a `Array.sort()`-based reference.
struct IntensityWindowSortTests {

    /// Reference reimplementation of `bounds` using `Array.sort()` — the exact
    /// pre-optimization algorithm. The production path must match this byte for
    /// byte across the inputs below.
    private static func referenceBounds(
        for values: [Float],
        lowerPercentile: Double,
        upperPercentile: Double
    ) -> (low: Float, high: Float)? {
        var finite = [Float]()
        var nonZero = [Float]()
        var minV = Float.greatestFiniteMagnitude
        var maxV = -Float.greatestFiniteMagnitude
        for v in values where v.isFinite {
            finite.append(v)
            if v < minV { minV = v }
            if v > maxV { maxV = v }
            if abs(v) > 1e-6 { nonZero.append(v) }
        }
        guard !finite.isEmpty else { return nil }
        let useNonZero = nonZero.count >= max(64, finite.count / 20)
        if useNonZero { nonZero.sort() } else { finite.sort() }
        let sorted = useNonZero ? nonZero : finite
        func percentile(_ p: Float) -> Float {
            guard let first = sorted.first else { return 0 }
            guard sorted.count > 1 else { return first }
            let pos = max(0, min(1, p)) * Float(sorted.count - 1)
            let lo = Int(pos.rounded(.down))
            let hi = Int(pos.rounded(.up))
            if lo == hi { return sorted[lo] }
            let frac = pos - Float(lo)
            return sorted[lo] * (1 - frac) + sorted[hi] * frac
        }
        let lower = percentile(Float(lowerPercentile) / 100)
        let upper = percentile(Float(upperPercentile) / 100)
        return lower < upper ? (lower, upper) : (minV, maxV)
    }

    private static func assertMatchesReference(
        _ values: [Float],
        lower: Double = 2,
        upper: Double = 98,
        _ comment: Comment
    ) {
        let produced = IntensityWindow.bounds(for: values, lowerPercentile: lower, upperPercentile: upper)
        let reference = referenceBounds(for: values, lowerPercentile: lower, upperPercentile: upper)
        switch (produced, reference) {
        case (nil, nil):
            break
        case let (p?, r?):
            // bitPattern compare: the windowed 8-bit output must be identical, so
            // the bounds themselves must match to the bit (not just approximately).
            #expect(p.low.bitPattern == r.low.bitPattern, comment)
            #expect(p.high.bitPattern == r.high.bitPattern, comment)
        default:
            Issue.record("nil mismatch: \(comment)")
        }
    }

    @Test func matchesReferenceOnStructuredData() {
        // Mixed magnitudes, many duplicates, a background of zeros — the typical
        // medical-volume shape that drives the non-zero-subset branch.
        var values = [Float]()
        for i in 0..<50_000 {
            values.append(i % 7 == 0 ? 0 : Float((i * 131 + 7) % 4096))
        }
        Self.assertMatchesReference(values, "structured")
    }

    @Test func matchesReferenceWithSignedZerosAndNegatives() {
        // ±0.0 are the only finite values that compare equal yet differ in bits;
        // confirm the percentile value lands identically regardless of how the
        // sort orders them.
        let values: [Float] = [-0.0, 0.0, -0.0, 0.0, -3.5, 3.5, -100, 100, 50, -50]
            + Array(repeating: 0.0, count: 200)
        Self.assertMatchesReference(values, "signed zeros")
    }

    @Test func matchesReferenceOnAllZeroBackground() {
        // Forces the finite-fallback branch (non-zero subset below threshold).
        let values = Array(repeating: Float(0), count: 1000) + [1, 2, 3]
        Self.assertMatchesReference(values, "all-zero background")
    }

    @Test func matchesReferenceOnPseudoRandomFloat() {
        var seed: UInt64 = 0xDEADBEEFCAFEBABE
        func nextFloat() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) * 2000 - 1000
        }
        let values = (0..<80_000).map { _ in nextFloat() }
        Self.assertMatchesReference(values, lower: 0.5, upper: 99.5, "pseudo-random")
    }

    @Test func emptyAndAllNonFiniteReturnNil() {
        #expect(IntensityWindow.bounds(for: [], lowerPercentile: 2, upperPercentile: 98) == nil)
        let nan = Float.nan
        let inf = Float.infinity
        #expect(IntensityWindow.bounds(for: [nan, inf, -inf], lowerPercentile: 2, upperPercentile: 98) == nil)
    }
}
