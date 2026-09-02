import Foundation

/// Percentile windowing for volumetric intensity data.
/// Maps a finite-valued float buffer to 8-bit grayscale.
enum IntensityWindow {
    struct Bounds: Sendable {
        let low: Float
        let high: Float
    }

    /// Derives window bounds from a pooled set of values. Pass voxels from one slice for
    /// per-slice windowing, or from multiple slices to get a window shared across them.
    /// Returns `nil` if no finite values are present.
    static func bounds(for values: [Float], lowerPercentile: Double, upperPercentile: Double) -> Bounds? {
        // One fused pass replaces the previous filter + filter + min + max chain:
        // collect finite values and the non-zero subset, tracking finite min/max
        // inline. Both buffers reserve `values.count` up front — the non-zero
        // subset is usually the bulk of a slice, so without it the array reallocs
        // and copies repeatedly as it grows into the hundreds of thousands.
        var finiteValues = [Float]()
        finiteValues.reserveCapacity(values.count)
        var nonZeroValues = [Float]()
        nonZeroValues.reserveCapacity(values.count)
        var minV = Float.greatestFiniteMagnitude
        var maxV = -Float.greatestFiniteMagnitude

        for value in values where value.isFinite {
            finiteValues.append(value)
            if value < minV { minV = value }
            if value > maxV { maxV = value }
            if abs(value) > 1e-6 {
                nonZeroValues.append(value)
            }
        }

        guard !finiteValues.isEmpty else {
            return nil
        }

        // Prefer a non-zero subset for windowing if it's substantial; otherwise fall back to all finite values.
        // The /20 ratio guards against rejecting legitimate dim regions when most voxels are background.
        let useNonZero = nonZeroValues.count >= max(64, finiteValues.count / 20)
        // Only four order statistics are ever read, so the buffer is *selected*
        // rather than sorted (quickselect, below). The k-th smallest of a multiset
        // is algorithm-independent, so this is bit-identical to the previous full
        // sort, not merely close — `IntensityWindowSortTests` pins that against an
        // `Array.sort()` reference. Mutate the chosen array directly (not a copy of
        // it) so the selection stays in place.
        let lower: Float
        let upper: Float
        if useNonZero {
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
        let range = max(bounds.high - bounds.low, 1e-6)
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
