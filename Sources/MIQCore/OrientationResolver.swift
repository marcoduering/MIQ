import Foundation

public struct SliceOrientationLabels: Sendable {
    public let leading: String
    public let trailing: String
    public let top: String
    public let bottom: String
    /// True when the file's orientation could not be determined and labels are
    /// placeholder "?" glyphs. The canvas renders these dimmed to signal the
    /// uncertainty rather than presenting a false anatomical claim.
    public let isUnknown: Bool

    public init(leading: String, trailing: String, top: String, bottom: String, isUnknown: Bool = false) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
        self.isUnknown = isUnknown
    }

    /// Placeholder labels shown only during initial loading, before the affine has been parsed.
    public static let placeholderCoronal = SliceOrientationLabels(leading: "L", trailing: "R", top: "S", bottom: "I")
    public static let placeholderSagittal = SliceOrientationLabels(leading: "P", trailing: "A", top: "S", bottom: "I")
    public static let placeholderAxial = SliceOrientationLabels(leading: "L", trailing: "R", top: "A", bottom: "P")

    /// Labels used when the file's anatomical orientation is genuinely undeterminable.
    public static let unknown = SliceOrientationLabels(leading: "?", trailing: "?", top: "?", bottom: "?", isUnknown: true)
}

/// Anatomical world axis (RAS basis).
public enum AnatomicalAxis: Hashable, Sendable {
    case rightLeft
    case anteriorPosterior
    case superiorInferior
}

/// Per-storage-axis anatomical role. `positive == true` means +storage matches +R / +A / +S
/// along `axis`; `positive == false` means +storage matches the negative direction (L / P / I).
public struct StorageAxisOrientation: Hashable, Sendable {
    public let axis: AnatomicalAxis
    public let positive: Bool

    public init(axis: AnatomicalAxis, positive: Bool) {
        self.axis = axis
        self.positive = positive
    }

    /// One-letter anatomical code: R/L/A/P/S/I.
    public var letter: String {
        switch (axis, positive) {
        case (.rightLeft, true): return "R"
        case (.rightLeft, false): return "L"
        case (.anteriorPosterior, true): return "A"
        case (.anteriorPosterior, false): return "P"
        case (.superiorInferior, true): return "S"
        case (.superiorInferior, false): return "I"
        }
    }

    /// The opposite anatomical direction along the same world axis.
    public var opposite: StorageAxisOrientation {
        StorageAxisOrientation(axis: axis, positive: !positive)
    }
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
///
/// Reads `MIQHeader.orientationFrame` as the single authoritative source. When the
/// frame is `nil`, labels become `.unknown` and the reoriented modes fall back to
/// `.stored` slicing — the volume still renders, but without making anatomical claims.
struct OrientationResolver {
    private let header: MIQHeader

    init(image: MIQImage) {
        self.header = image.header
    }

    /// 3-letter storage orientation (e.g. "RAS", "LAS"), or nil if undeterminable.
    func storageLabel() -> String? {
        header.orientationFrame.map { $0.axes.map(\.letter).joined() }
    }

    func displayOrientation(for plane: SlicePlane) -> SliceOrientationLabels {
        guard let frame = header.orientationFrame else { return .unknown }
        let mapping = displayMapping(for: plane)
        let h = frame.axes[mapping.horizontalAxis]
        let v = frame.axes[mapping.verticalAxis]

        // Stored plan: hReversed=false, vReversed=true. Column dim-1 (trailing) is
        // the +storage end of the h axis; row 0 (top) is the +storage end of v.
        return SliceOrientationLabels(
            leading: h.opposite.letter,
            trailing: h.letter,
            top: v.letter,
            bottom: v.opposite.letter
        )
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

    /// Per-storage-axis anatomical role, or `nil` when the orientation frame is absent.
    /// Reoriented view modes fall back to `.stored` when this is `nil`.
    func storageAxisOrientations() -> [StorageAxisOrientation]? {
        header.orientationFrame?.axes
    }

    /// Produces a slice-extraction plan for a given anatomical plane in the requested
    /// view orientation. Falls back to the `.stored` plan whenever the affine is
    /// undeterminable. The `.stored` plan reproduces the legacy per-plane mapping exactly.
    func plan(for plane: SlicePlane, mode: ViewOrientation) -> SliceAxisPlan {
        switch mode {
        case .stored:
            return storedPlan(for: plane)
        case .neurological, .radiological:
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
            // Neurological: +R at trailing edge; radiological mirrors horizontally. Vertical: +S at top in both.
            let isNeurological = (mode == .neurological)
            return AnatomicalTarget(
                sliceAnatomy: .anteriorPosterior,
                hAnatomy: .rightLeft,
                vAnatomy: .superiorInferior,
                hPositive: isNeurological,
                vPositive: true,
                labels: SliceOrientationLabels(
                    leading: isNeurological ? "L" : "R",
                    trailing: isNeurological ? "R" : "L",
                    top: "S",
                    bottom: "I"
                )
            )
        case .sagittal:
            // No L/R component in the plane; neurological/radiological render identically.
            // Both conventions display sagittal with anterior on viewer's left.
            return AnatomicalTarget(
                sliceAnatomy: .rightLeft,
                hAnatomy: .anteriorPosterior,
                vAnatomy: .superiorInferior,
                hPositive: false,
                vPositive: true,
                labels: SliceOrientationLabels(leading: "A", trailing: "P", top: "S", bottom: "I")
            )
        case .axial:
            // Neurological: +R at trailing edge; radiological mirrors horizontally. Vertical: +A at top in both.
            let isNeurological = (mode == .neurological)
            return AnatomicalTarget(
                sliceAnatomy: .superiorInferior,
                hAnatomy: .rightLeft,
                vAnatomy: .anteriorPosterior,
                hPositive: isNeurological,
                vPositive: true,
                labels: SliceOrientationLabels(
                    leading: isNeurological ? "L" : "R",
                    trailing: isNeurological ? "R" : "L",
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

}
