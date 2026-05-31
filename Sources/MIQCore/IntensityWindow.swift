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
        // inline. The chosen window source is then sorted *in place* (we own both
        // buffers), avoiding the extra copy `.sorted()` made. Output is bit-identical
        // to the old sort-based path — the rendered preview must not change.
        var finiteValues = [Float]()
        finiteValues.reserveCapacity(values.count)
        var nonZeroValues = [Float]()
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
        if useNonZero {
            nonZeroValues.sort()
        } else {
            finiteValues.sort()
        }
        let sorted = useNonZero ? nonZeroValues : finiteValues

        let lower = percentile(sorted, p: Float(lowerPercentile) / 100.0)
        let upper = percentile(sorted, p: Float(upperPercentile) / 100.0)
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

    private static func percentile(_ sorted: [Float], p: Float) -> Float {
        guard let first = sorted.first else {
            return 0
        }
        guard sorted.count > 1 else {
            return first
        }

        let clamped = max(0, min(1, p))
        let position = clamped * Float(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))

        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }

        let fraction = position - Float(lowerIndex)
        return sorted[lowerIndex] * (1 - fraction) + sorted[upperIndex] * fraction
    }
}
