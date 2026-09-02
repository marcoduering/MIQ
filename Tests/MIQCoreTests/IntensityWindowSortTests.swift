import Foundation
import Testing
@testable import MIQCore

/// `IntensityWindow.bounds` reads at most four order statistics, so it selects
/// (quickselect) instead of sorting the pooled buffer. The k-th smallest of a
/// multiset is algorithm-independent, so the rendered preview must not change —
/// these pin the windowed output bit-identical to an `Array.sort()`-based
/// reference, which is also the pre-optimization algorithm.
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

    @Test func matchesReferenceOnConstantBuffer() {
        // Every element equal: both percentiles collapse to the same value, so the
        // `lower < upper` tail rule fires and the bounds come from min/max instead.
        // Also the worst case for a first-element pivot — median-of-three's reason.
        Self.assertMatchesReference(Array(repeating: Float(7), count: 5000), "constant non-zero")
        Self.assertMatchesReference(Array(repeating: Float(0), count: 5000), "constant zero")
    }

    @Test func matchesReferenceOnSingleValue() {
        // n == 1: both percentile indices resolve to 0 and the tail rule fires.
        Self.assertMatchesReference([42], "single value")
        Self.assertMatchesReference([-3.25], "single negative value")
        // n == 1 after non-finite filtering, from a longer buffer.
        Self.assertMatchesReference([.nan, .infinity, 17, -.infinity], "single finite among non-finite")
    }

    @Test func matchesReferenceOnSortedAndReversedInput() {
        // Already-ordered input is the pathological case for a naive pivot.
        let ascending = (0..<40_000).map { Float($0) }
        Self.assertMatchesReference(ascending, "ascending")
        Self.assertMatchesReference(ascending.reversed(), "descending")
    }

    @Test func matchesReferenceAcrossPercentilePairs() {
        // The index arithmetic differs at the extremes (position lands exactly on an
        // element, so the two indices coincide) and when both percentiles are equal.
        var values = [Float]()
        for i in 0..<20_000 {
            values.append(i % 5 == 0 ? 0 : Float((i * 37 + 11) % 1000) - 500)
        }
        for (lo, hi) in [(0.0, 100.0), (50.0, 50.0), (1.0, 99.0), (25.0, 75.0), (99.0, 1.0)] {
            Self.assertMatchesReference(values, lower: lo, upper: hi, "percentiles \(lo)/\(hi)")
        }
    }

    @Test func matchesReferenceWithNonFiniteInterleaved() {
        // Non-finite values must not reach the selection loops (their comparisons
        // would let the partition scan run off the end of the buffer).
        var values = [Float]()
        for i in 0..<10_000 {
            switch i % 11 {
            case 0: values.append(.nan)
            case 1: values.append(.infinity)
            case 2: values.append(-.infinity)
            default: values.append(Float((i * 17) % 2048) - 1024)
            }
        }
        Self.assertMatchesReference(values, "non-finite interleaved")
    }
}
