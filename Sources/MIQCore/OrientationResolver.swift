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
