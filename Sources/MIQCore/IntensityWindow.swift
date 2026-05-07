import Foundation

/// 2nd-to-98th percentile windowing for volumetric intensity data.
/// Maps a finite-valued float buffer to 8-bit grayscale.
enum IntensityWindow {
    static func normalize(_ values: [Float]) -> [UInt8] {
        let finiteValues = values.filter { $0.isFinite }
        guard !finiteValues.isEmpty else {
            return []
        }

        // Prefer a non-zero subset for windowing if it's substantial; otherwise fall back to all finite values.
        // The /20 ratio guards against rejecting legitimate dim regions when most voxels are background.
        let nonZeroValues = finiteValues.filter { abs($0) > 1e-6 }
        let windowSource = nonZeroValues.count >= max(64, finiteValues.count / 20) ? nonZeroValues : finiteValues
        let sorted = windowSource.sorted()

        let lower = percentile(sorted, p: 0.02)
        let upper = percentile(sorted, p: 0.98)
        let minV = finiteValues.min() ?? lower
        let maxV = finiteValues.max() ?? upper
        let windowLow = lower < upper ? lower : minV
        let windowHigh = lower < upper ? upper : maxV
        let range = max(windowHigh - windowLow, 1e-6)

        return values.map { value in
            guard value.isFinite else {
                return 0
            }

            let clipped = max(windowLow, min(windowHigh, value))
            let unit = max(0, min(1, (clipped - windowLow) / range))
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
