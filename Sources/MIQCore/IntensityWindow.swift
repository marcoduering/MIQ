import Foundation

/// Percentile windowing for volumetric intensity data.
/// Maps a finite-valued float buffer to 8-bit grayscale.
enum IntensityWindow {
    struct Bounds: Sendable {
        let low: Float
        let high: Float
    }

    /// Magnitude at or below which a value counts as background for the preferred
    /// foreground subset (see `bounds`).
    static let nonZeroFloor: Float = 1e-6

    /// Derives window bounds from a pooled set of values. Pass voxels from one slice for
    /// per-slice windowing, or from multiple slices to get a window shared across them.
    /// Returns `nil` if no finite values are present.
    static func bounds(for values: [Float], lowerPercentile: Double, upperPercentile: Double) -> Bounds? {
        // One fused pass: collect finite values and the above-floor subset, track
        // finite min/max, and count exact non-zeros for the rare fallback tier.
        // Both buffers reserve `values.count` up front — the subset is usually the
        // bulk of a slice, so without it the array reallocs repeatedly as it grows
        // into the hundreds of thousands.
        var finiteValues = [Float]()
        finiteValues.reserveCapacity(values.count)
        var aboveFloorValues = [Float]()
        aboveFloorValues.reserveCapacity(values.count)
        var minV = Float.greatestFiniteMagnitude
        var maxV = -Float.greatestFiniteMagnitude
        var nonZeroCount = 0

        for value in values where value.isFinite {
            finiteValues.append(value)
            if value < minV { minV = value }
            if value > maxV { maxV = value }
            if value != 0 {
                nonZeroCount += 1
                if abs(value) > nonZeroFloor { aboveFloorValues.append(value) }
            }
        }

        guard !finiteValues.isEmpty else {
            return nil
        }

        // Window over the foreground when it's substantial; the /20 ratio keeps a
        // dim region from being rejected when most voxels are background.
        //
        // Two tiers, tried in order. The 1e-6 floor also drops near-zero
        // interpolation residue, and wins whenever it leaves enough voxels — every
        // ordinary image, bit-identical to before. Only when it doesn't (data in
        // tiny units: an SI-unit ADC map sits around 1e-9, *entirely* below the
        // floor) do exactly-non-zero values stand in, so such a map windows over its
        // tissue instead of over tissue plus background zeros. Deliberately not a
        // floor scaled by the data's maximum: one outlier voxel (1e30 from a failed
        // fit) would lift that above real tissue.
        let minimumSubset = max(64, finiteValues.count / 20)

        // Only four order statistics are ever read, so the buffer is *selected*
        // rather than sorted (quickselect, below). The k-th smallest of a multiset
        // is algorithm-independent, so this is bit-identical to a full sort, not
        // merely close — `IntensityWindowSortTests` pins that against an
        // `Array.sort()` reference. The chosen array is mutated in place.
        let lower: Float
        let upper: Float
        if aboveFloorValues.count >= minimumSubset {
            (lower, upper) = percentileBounds(&aboveFloorValues, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
        } else if nonZeroCount >= minimumSubset {
            // Tiny-unit fallback — the only case that pays a second pass.
            var nonZeroValues = [Float]()
            nonZeroValues.reserveCapacity(nonZeroCount)
            for value in finiteValues where value != 0 {
                nonZeroValues.append(value)
            }
            (lower, upper) = percentileBounds(&nonZeroValues, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
        } else {
            (lower, upper) = percentileBounds(&finiteValues, lowerPercentile: lowerPercentile, upperPercentile: upperPercentile)
        }
        let windowLow = lower < upper ? lower : minV
        let windowHigh = lower < upper ? upper : maxV
        return Bounds(low: windowLow, high: windowHigh)
    }

    /// Applies precomputed window bounds to `values`, producing 8-bit grayscale.
    static func apply(_ values: [Float], bounds: Bounds) -> [UInt8] {
        // No absolute floor on the width: float data can legitimately span far less
        // than 1e-6 (ADC maps in SI units sit around 1e-9), and a floor squashed such
        // a window into one or two grey levels. A degenerate window (high <= low)
        // clips every value to `low`, so the numerator is 0 and any positive divisor
        // gives black; 1 just keeps the division finite.
        let width = bounds.high - bounds.low
        let range = width > 0 ? width : 1
        return values.map { value in
            guard value.isFinite else {
                return 0
            }

            let clipped = max(bounds.low, min(bounds.high, value))
            let unit = max(0, min(1, (clipped - bounds.low) / range))
            return UInt8((unit * 255).rounded())
        }
    }

    // MARK: - Percentile selection

    /// The two array positions a percentile interpolates between, and the weight
    /// between them. Index arithmetic is shared by every path so they cannot drift.
    private struct PercentilePosition {
        let lowerIndex: Int
        let upperIndex: Int
        let fraction: Float
    }

    private static func position(count: Int, p: Float) -> PercentilePosition {
        let clamped = max(0, min(1, p))
        let position = clamped * Float(count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        return PercentilePosition(
            lowerIndex: lowerIndex,
            upperIndex: upperIndex,
            fraction: position - Float(lowerIndex)
        )
    }

    /// Resolves both percentiles of `buffer` in place. The buffer is left partially
    /// ordered (only the positions actually read are placed), which is all the
    /// percentile interpolation needs.
    private static func percentileBounds(
        _ buffer: inout [Float],
        lowerPercentile: Double,
        upperPercentile: Double
    ) -> (Float, Float) {
        guard !buffer.isEmpty else {
            return (0, 0)
        }

        let lowerPosition = position(count: buffer.count, p: Float(lowerPercentile) / 100.0)
        let upperPosition = position(count: buffer.count, p: Float(upperPercentile) / 100.0)

        return buffer.withUnsafeMutableBufferPointer { buf -> (Float, Float) in
            // Resolve the (at most four) needed indices in ascending order. After
            // `select` fixes index k over [start, n), every element below k is ≤
            // buf[k], so the next select only has to search above it — and buf[k]
            // itself is never disturbed again.
            var wanted = [
                lowerPosition.lowerIndex, lowerPosition.upperIndex,
                upperPosition.lowerIndex, upperPosition.upperIndex,
            ]
            wanted.sort()
            var start = 0
            for k in wanted {
                if k < start { continue }  // duplicate index, already placed
                select(buf, k: k, from: start)
                start = k + 1
            }
            return (value(at: lowerPosition, in: buf), value(at: upperPosition, in: buf))
        }
    }

    private static func value(at position: PercentilePosition, in buf: UnsafeMutableBufferPointer<Float>) -> Float {
        if position.lowerIndex == position.upperIndex {
            return buf[position.lowerIndex]
        }
        let fraction = position.fraction
        return buf[position.lowerIndex] * (1 - fraction) + buf[position.upperIndex] * fraction
    }

    /// Iterative Hoare quickselect: rearranges `buf[start...]` so `buf[k]` holds the
    /// k-th smallest element of the whole buffer, given that everything below `start`
    /// is already ≤ everything at or above it.
    ///
    /// The caller filters the buffer to finite values, so the scanning loops cannot
    /// run off the ends on a NaN comparison. Iterative, so a pathological pivot
    /// sequence costs time rather than stack.
    private static func select(_ buf: UnsafeMutableBufferPointer<Float>, k: Int, from start: Int) {
        var lo = start
        var hi = buf.count - 1
        while lo < hi {
            placePivot(buf, lo, hi)
            let pivot = buf[lo]
            var i = lo - 1
            var j = hi + 1
            while true {
                repeat { i += 1 } while buf[i] < pivot
                repeat { j -= 1 } while buf[j] > pivot
                if i >= j { break }
                buf.swapAt(i, j)
            }
            // Hoare's invariant with a pivot taken from buf[lo] guarantees
            // lo ≤ j < hi, so each iteration strictly shrinks the range.
            if k <= j {
                hi = j
            } else {
                lo = j + 1
            }
        }
    }

    /// Median-of-three, left at `buf[lo]` for the partition to use as its pivot.
    /// A first-element pivot degrades on sorted or constant input — the common
    /// shape here, where most of a slice is identical background.
    private static func placePivot(_ buf: UnsafeMutableBufferPointer<Float>, _ lo: Int, _ hi: Int) {
        let mid = lo + (hi - lo) / 2
        if buf[mid] < buf[lo] { buf.swapAt(mid, lo) }
        if buf[hi] < buf[lo] { buf.swapAt(hi, lo) }
        if buf[hi] < buf[mid] { buf.swapAt(hi, mid) }
        buf.swapAt(lo, mid)
    }
}
