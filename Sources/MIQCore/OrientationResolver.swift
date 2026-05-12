import Foundation

public struct SliceOrientationLabels: Sendable {
    public let leading: String
    public let trailing: String
    public let top: String
    public let bottom: String

    public init(leading: String, trailing: String, top: String, bottom: String) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
    }

    /// Placeholder labels shown only during initial loading, before the affine has been parsed.
    public static let placeholderCoronal = SliceOrientationLabels(leading: "L", trailing: "R", top: "S", bottom: "I")
    public static let placeholderSagittal = SliceOrientationLabels(leading: "P", trailing: "A", top: "S", bottom: "I")
    public static let placeholderAxial = SliceOrientationLabels(leading: "L", trailing: "R", top: "A", bottom: "P")
}

/// Anatomical world axis (RAS basis).
enum AnatomicalAxis: Hashable {
    case rightLeft
    case anteriorPosterior
    case superiorInferior
}

/// Per-storage-axis anatomical role. `positive == true` means +storage matches +R / +A / +S
/// along `axis`; `positive == false` means +storage matches the negative direction (L / P / I).
struct StorageAxisOrientation: Hashable {
    let axis: AnatomicalAxis
    let positive: Bool
}

/// Resolved slice-extraction plan. The fields drive `SliceConfig` directly:
/// pick the storage axis to slice along, choose horizontal/vertical iteration storage
/// axes, and flag whether to walk each in reverse.
struct SliceAxisPlan {
    let sliceAxis: Int      // storage axis index 0..2
    let hAxis: Int          // storage axis index for displayed horizontal
    let vAxis: Int          // storage axis index for displayed vertical
    let hReversed: Bool     // iterate hAxis from dim-1 down to 0
    let vReversed: Bool     // iterate vAxis from dim-1 down to 0 (top row of buffer = +storage end)
    let labels: SliceOrientationLabels
}

/// Maps voxel axes to anatomical (RAS) world directions and produces display labels.
struct OrientationResolver {
    private let header: MIQHeader
    private let storedOverride: String?

    init(image: MIQImage) {
        self.header = image.header
        self.storedOverride = image.orientationLabel
    }

    /// 3-letter storage orientation (e.g. "RAS", "LAS"), or nil if undeterminable.
    func storageLabel() -> String? {
        if let storedOverride { return storedOverride }
        guard header.sformCode > 0 else { return nil }
        let world = worldAxisDirections()
        return world.prefix(3).map { Self.anatomicalLabel(for: $0) }.joined()
    }

    func displayOrientation(for plane: SlicePlane) -> SliceOrientationLabels {
        let world = worldAxisDirections()
        let mapping = displayMapping(for: plane)

        let horizontalDirection = world[mapping.horizontalAxis]
        let verticalDirection = world[mapping.verticalAxis]

        let trailing = Self.anatomicalLabel(for: horizontalDirection)
        let leading = Self.opposite(of: trailing)
        let top = Self.anatomicalLabel(for: verticalDirection)
        let bottom = Self.opposite(of: top)

        return SliceOrientationLabels(leading: leading, trailing: trailing, top: top, bottom: bottom)
    }

    private func worldAxisDirections() -> [(x: Float, y: Float, z: Float)] {
        if header.sformCode > 0 {
            let iAxis = (
                x: header.srowX[safe: 0] ?? 0,
                y: header.srowY[safe: 0] ?? 0,
                z: header.srowZ[safe: 0] ?? 0
            )
            let jAxis = (
                x: header.srowX[safe: 1] ?? 0,
                y: header.srowY[safe: 1] ?? 0,
                z: header.srowZ[safe: 1] ?? 0
            )
            let kAxis = (
                x: header.srowX[safe: 2] ?? 0,
                y: header.srowY[safe: 2] ?? 0,
                z: header.srowZ[safe: 2] ?? 0
            )

            if Self.squaredNorm(iAxis) > 0, Self.squaredNorm(jAxis) > 0, Self.squaredNorm(kAxis) > 0 {
                return [iAxis, jAxis, kAxis]
            }
        }

        return [
            (x: 1, y: 0, z: 0),
            (x: 0, y: 1, z: 0),
            (x: 0, y: 0, z: 1)
        ]
    }

    private struct DisplayMapping {
        let horizontalAxis: Int
        let verticalAxis: Int
    }

    private func displayMapping(for plane: SlicePlane) -> DisplayMapping {
        switch plane {
        case .coronal:
            return DisplayMapping(horizontalAxis: 0, verticalAxis: 2)
        case .sagittal:
            return DisplayMapping(horizontalAxis: 1, verticalAxis: 2)
        case .axial:
            return DisplayMapping(horizontalAxis: 0, verticalAxis: 1)
        }
    }

    // MARK: - Reorientation

    /// Per-storage-axis anatomical role, or `nil` when the affine is undeterminable
    /// (no MIF orientation override, no sform, or the resolved roles are degenerate).
    /// `.ras`/`.las` view modes fall back to `.stored` when this is `nil`.
    func storageAxisOrientations() -> [StorageAxisOrientation]? {
        if let label = storedOverride, label.count == 3 {
            var result: [StorageAxisOrientation] = []
            result.reserveCapacity(3)
            for char in label {
                guard let entry = Self.orientation(for: char) else { return nil }
                result.append(entry)
            }
            return Self.hasDistinctAxes(result) ? result : nil
        }

        guard let world = realWorldAxisDirections() else { return nil }
        let result = world.map { Self.anatomy(of: $0) }
        return Self.hasDistinctAxes(result) ? result : nil
    }

    /// Produces a slice-extraction plan for a given anatomical plane in the requested
    /// view orientation. Falls back to the `.stored` plan whenever the affine is
    /// undeterminable. The `.stored` plan reproduces the legacy per-plane mapping exactly.
    func plan(for plane: SlicePlane, mode: ViewOrientation) -> SliceAxisPlan {
        switch mode {
        case .stored:
            return storedPlan(for: plane)
        case .ras, .las:
            guard let axes = storageAxisOrientations() else {
                return storedPlan(for: plane)
            }
            return reorientedPlan(for: plane, mode: mode, storageAxes: axes)
        }
    }

    private func storedPlan(for plane: SlicePlane) -> SliceAxisPlan {
        let labels = displayOrientation(for: plane)
        switch plane {
        case .coronal:
            return SliceAxisPlan(sliceAxis: 1, hAxis: 0, vAxis: 2, hReversed: false, vReversed: true, labels: labels)
        case .sagittal:
            return SliceAxisPlan(sliceAxis: 0, hAxis: 1, vAxis: 2, hReversed: false, vReversed: true, labels: labels)
        case .axial:
            return SliceAxisPlan(sliceAxis: 2, hAxis: 0, vAxis: 1, hReversed: false, vReversed: true, labels: labels)
        }
    }

    private struct AnatomicalTarget {
        let sliceAnatomy: AnatomicalAxis
        let hAnatomy: AnatomicalAxis
        let vAnatomy: AnatomicalAxis
        let hPositive: Bool
        let vPositive: Bool
        let labels: SliceOrientationLabels
    }

    private func anatomicalTarget(for plane: SlicePlane, mode: ViewOrientation) -> AnatomicalTarget {
        switch plane {
        case .coronal:
            // RAS: +R at trailing edge; LAS mirrors horizontally. Vertical: +S at top in both.
            let isRAS = (mode == .ras)
            return AnatomicalTarget(
                sliceAnatomy: .anteriorPosterior,
                hAnatomy: .rightLeft,
                vAnatomy: .superiorInferior,
                hPositive: isRAS,
                vPositive: true,
                labels: SliceOrientationLabels(
                    leading: isRAS ? "L" : "R",
                    trailing: isRAS ? "R" : "L",
                    top: "S",
                    bottom: "I"
                )
            )
        case .sagittal:
            // No L/R component in the plane; RAS/LAS render identically (A on trailing, S on top).
            return AnatomicalTarget(
                sliceAnatomy: .rightLeft,
                hAnatomy: .anteriorPosterior,
                vAnatomy: .superiorInferior,
                hPositive: true,
                vPositive: true,
                labels: SliceOrientationLabels(leading: "P", trailing: "A", top: "S", bottom: "I")
            )
        case .axial:
            // RAS: +R at trailing edge; LAS mirrors horizontally. Vertical: +A at top in both.
            let isRAS = (mode == .ras)
            return AnatomicalTarget(
                sliceAnatomy: .superiorInferior,
                hAnatomy: .rightLeft,
                vAnatomy: .anteriorPosterior,
                hPositive: isRAS,
                vPositive: true,
                labels: SliceOrientationLabels(
                    leading: isRAS ? "L" : "R",
                    trailing: isRAS ? "R" : "L",
                    top: "A",
                    bottom: "P"
                )
            )
        }
    }

    private func reorientedPlan(
        for plane: SlicePlane,
        mode: ViewOrientation,
        storageAxes: [StorageAxisOrientation]
    ) -> SliceAxisPlan {
        let target = anatomicalTarget(for: plane, mode: mode)

        // storageAxes is guaranteed distinct by storageAxisOrientations(), so each lookup hits exactly once.
        let sliceAxis = storageAxes.firstIndex(where: { $0.axis == target.sliceAnatomy })!
        let hAxis = storageAxes.firstIndex(where: { $0.axis == target.hAnatomy })!
        let vAxis = storageAxes.firstIndex(where: { $0.axis == target.vAnatomy })!

        // For horizontal iteration: pixels are filled left-to-right, so col 0 = left.
        //   storage forward yields left = -storage. We want left = -desiredHPositive direction.
        //   → reverse iff storage direction opposes the desired direction.
        let hReversed = storageAxes[hAxis].positive != target.hPositive

        // For vertical iteration: pixels are filled top-to-bottom, so row 0 = top of image.
        //   Reversed iteration (the legacy default for "stored" mode) puts +storage at the top.
        //   We want top = +desiredVPositive direction.
        //   → reverse iff storage direction matches the desired direction.
        let vReversed = storageAxes[vAxis].positive == target.vPositive

        return SliceAxisPlan(
            sliceAxis: sliceAxis,
            hAxis: hAxis,
            vAxis: vAxis,
            hReversed: hReversed,
            vReversed: vReversed,
            labels: target.labels
        )
    }

    /// Real sform-derived world axis vectors, or nil when sform is absent or all-zero.
    /// Unlike `worldAxisDirections()` this never silently falls back to identity.
    private func realWorldAxisDirections() -> [(x: Float, y: Float, z: Float)]? {
        guard header.sformCode > 0 else { return nil }
        let iAxis = (
            x: header.srowX[safe: 0] ?? 0,
            y: header.srowY[safe: 0] ?? 0,
            z: header.srowZ[safe: 0] ?? 0
        )
        let jAxis = (
            x: header.srowX[safe: 1] ?? 0,
            y: header.srowY[safe: 1] ?? 0,
            z: header.srowZ[safe: 1] ?? 0
        )
        let kAxis = (
            x: header.srowX[safe: 2] ?? 0,
            y: header.srowY[safe: 2] ?? 0,
            z: header.srowZ[safe: 2] ?? 0
        )
        guard Self.squaredNorm(iAxis) > 0,
              Self.squaredNorm(jAxis) > 0,
              Self.squaredNorm(kAxis) > 0 else {
            return nil
        }
        return [iAxis, jAxis, kAxis]
    }

    private static func anatomy(of v: (x: Float, y: Float, z: Float)) -> StorageAxisOrientation {
        let label = anatomicalLabel(for: v)
        // anatomicalLabel always returns one of R/L/A/P/S/I, so the lookup never fails.
        return orientation(for: Character(label))!
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

    private static func hasDistinctAxes(_ list: [StorageAxisOrientation]) -> Bool {
        Set(list.map { $0.axis }).count == list.count
    }

    private static func squaredNorm(_ v: (x: Float, y: Float, z: Float)) -> Float {
        v.x * v.x + v.y * v.y + v.z * v.z
    }

    static func anatomicalLabel(for v: (x: Float, y: Float, z: Float)) -> String {
        let ax = abs(v.x)
        let ay = abs(v.y)
        let az = abs(v.z)

        if ax >= ay && ax >= az {
            return v.x >= 0 ? "R" : "L"
        }
        if ay >= ax && ay >= az {
            return v.y >= 0 ? "A" : "P"
        }
        return v.z >= 0 ? "S" : "I"
    }

    static func opposite(of label: String) -> String {
        switch label {
        case "R": return "L"
        case "L": return "R"
        case "A": return "P"
        case "P": return "A"
        case "S": return "I"
        case "I": return "S"
        default: return label
        }
    }
}
