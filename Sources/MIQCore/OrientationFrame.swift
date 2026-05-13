import Foundation

/// Provenance of an `OrientationFrame` — which header field the anatomical
/// mapping was derived from. Useful for diagnostics and for tie-breaking when
/// multiple sources are present.
public enum OrientationSource: String, Sendable, Hashable {
    case sform
    case qform
    case mifLayout
    case mghDirectionCosines
    case nrrdSpaceDirections
}

/// Authoritative per-storage-axis anatomical mapping for a volume. When non-nil,
/// every storage axis has a distinct anatomical role (R/L, A/P, S/I); when nil,
/// the file's orientation is genuinely undeterminable.
///
/// Built once at parse time by each format-specific parser, then consumed by
/// `OrientationResolver` as the single source of truth for both display labels
/// and slice planning. `nil` causes the resolver to emit `SliceOrientationLabels.unknown`
/// and `.ras`/`.las` view modes to fall back to `.stored` slicing.
public struct OrientationFrame: Sendable, Hashable {
    public let axes: [StorageAxisOrientation]
    public let source: OrientationSource

    public init(axes: [StorageAxisOrientation], source: OrientationSource) {
        self.axes = axes
        self.source = source
    }

    /// Build a frame from three sform-style row vectors (one per world axis: x, y, z).
    /// Each storage axis's anatomical role is determined by the dominant component
    /// of its column across the three rows. Returns nil when any column is
    /// all-zero or when two columns map to the same anatomical axis.
    public static func from(
        srowX: [Float],
        srowY: [Float],
        srowZ: [Float],
        source: OrientationSource
    ) -> OrientationFrame? {
        var axes: [StorageAxisOrientation] = []
        axes.reserveCapacity(3)
        for col in 0..<3 {
            let v = (
                x: srowX[safe: col] ?? 0,
                y: srowY[safe: col] ?? 0,
                z: srowZ[safe: col] ?? 0
            )
            if v.x * v.x + v.y * v.y + v.z * v.z == 0 { return nil }
            axes.append(anatomy(of: v))
        }
        guard Set(axes.map { $0.axis }).count == axes.count else { return nil }
        return OrientationFrame(axes: axes, source: source)
    }

    /// Build a frame from a NIfTI qform quaternion. `qfac` is `pixdim[0]`'s sign
    /// (+1 or -1) — the spec reflects the k-axis when `qfac < 0`. Caller must
    /// only invoke this when `qform_code > 0`; passing all-zero `b/c/d` with
    /// `qfac = 0` will fail the distinct-axes check and return nil.
    public static func fromQuaternion(b: Float, c: Float, d: Float, qfac: Float) -> OrientationFrame? {
        let aSquared = max(0, 1 - b * b - c * c - d * d)
        let a = aSquared.squareRoot()
        let qfacSign: Float = qfac < 0 ? -1 : 1

        // NIfTI-1 spec: R = [[a²+b²-c²-d², 2(bc-ad), 2(bd+ac)],
        //                   [2(bc+ad), a²+c²-b²-d², 2(cd-ab)],
        //                   [2(bd-ac), 2(cd+ab), a²+d²-b²-c²]]
        // The third column is then scaled by qfac to account for left-handed coords.
        let r00 = a * a + b * b - c * c - d * d
        let r01 = 2 * (b * c - a * d)
        let r02 = 2 * (b * d + a * c) * qfacSign
        let r10 = 2 * (b * c + a * d)
        let r11 = a * a + c * c - b * b - d * d
        let r12 = 2 * (c * d - a * b) * qfacSign
        let r20 = 2 * (b * d - a * c)
        let r21 = 2 * (c * d + a * b)
        let r22 = (a * a + d * d - b * b - c * c) * qfacSign

        return from(
            srowX: [r00, r01, r02],
            srowY: [r10, r11, r12],
            srowZ: [r20, r21, r22],
            source: .qform
        )
    }

    /// Build a frame from a 3-letter MRtrix MIF orientation label (e.g. "RAS", "LAS").
    /// Returns nil when the string is malformed or yields non-distinct axes.
    public static func fromMifLabel(_ label: String) -> OrientationFrame? {
        guard label.count == 3 else { return nil }
        var axes: [StorageAxisOrientation] = []
        axes.reserveCapacity(3)
        for char in label {
            guard let entry = orientation(for: char) else { return nil }
            axes.append(entry)
        }
        guard Set(axes.map { $0.axis }).count == axes.count else { return nil }
        return OrientationFrame(axes: axes, source: .mifLayout)
    }

    // MARK: - Helpers (mirror OrientationResolver's logic; kept local so the
    // resolver remains the single owner of slice planning while this type owns
    // header-derived orientation construction.)

    private static func anatomy(of v: (x: Float, y: Float, z: Float)) -> StorageAxisOrientation {
        let ax = abs(v.x)
        let ay = abs(v.y)
        let az = abs(v.z)

        if ax >= ay && ax >= az {
            return StorageAxisOrientation(axis: .rightLeft, positive: v.x >= 0)
        }
        if ay >= ax && ay >= az {
            return StorageAxisOrientation(axis: .anteriorPosterior, positive: v.y >= 0)
        }
        return StorageAxisOrientation(axis: .superiorInferior, positive: v.z >= 0)
    }

    private static func orientation(for char: Character) -> StorageAxisOrientation? {
        switch char {
        case "R": return StorageAxisOrientation(axis: .rightLeft, positive: true)
        case "L": return StorageAxisOrientation(axis: .rightLeft, positive: false)
        case "A": return StorageAxisOrientation(axis: .anteriorPosterior, positive: true)
        case "P": return StorageAxisOrientation(axis: .anteriorPosterior, positive: false)
        case "S": return StorageAxisOrientation(axis: .superiorInferior, positive: true)
        case "I": return StorageAxisOrientation(axis: .superiorInferior, positive: false)
        default: return nil
        }
    }
}
