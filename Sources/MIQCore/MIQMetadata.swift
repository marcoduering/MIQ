import Foundation

public enum MetadataField: String, Sendable, CaseIterable {
    case format
    case dimensions
    case spacing
    case orientation
    case datatype
    case volumes
    case scaling
}

public struct MetadataEntry: Sendable {
    public let field: MetadataField?
    public let text: String

    public init(field: MetadataField?, text: String) {
        self.field = field
        self.text = text
    }
}

public struct MIQMetadata: Sendable {
    public let dimensions: String
    public let spacing: String
    public let datatype: String
    public let volumes: Int
    public let sclSlope: Float
    public let sclInter: Float
    public let orientation: String?

    public init(header: MIQHeader, orientation: String? = nil) {
        dimensions = "\(header.width) x \(header.height) x \(header.depth)"

        let x = header.pixdim[safe: 1] ?? 1
        let y = header.pixdim[safe: 2] ?? 1
        let z = header.pixdim[safe: 3] ?? 1
        spacing = String(format: "%.2f x %.2f x %.2f mm", x, y, z)

        datatype = header.datatype.label
        volumes = header.volumes
        sclSlope = header.sclSlope
        sclInter = header.sclInter
        self.orientation = orientation
    }

    public func asDisplayLines() -> [MetadataEntry] {
        var entries: [MetadataEntry] = [
            MetadataEntry(field: .dimensions, text: "Dimensions: \(dimensions)"),
            MetadataEntry(field: .spacing, text: "Spacing: \(spacing)"),
        ]
        if let orientation {
            entries.append(MetadataEntry(field: .orientation, text: "Orientation: \(orientation)"))
        }
        entries.append(MetadataEntry(field: .datatype, text: "Datatype: \(datatype)"))
        entries.append(MetadataEntry(field: .volumes, text: "Volumes: \(volumes)"))
        if let scaling {
            entries.append(MetadataEntry(field: .scaling, text: "Scaling: \(scaling)"))
        }
        return entries
    }

    private var scaling: String? {
        let slope = Double(sclSlope)
        let intercept = Double(sclInter)
        let epsilon = 1e-6

        // `scl_slope == 0` means "do not apply scaling" in the current voxel path,
        // so hide the row rather than showing a misleading x 0.000 + ... expression.
        guard abs(slope) > epsilon else { return nil }
        guard !(abs(slope - 1) <= epsilon && abs(intercept) <= epsilon) else { return nil }

        let sign = intercept < 0 ? "-" : "+"
        return String(format: "x %.3f %@ %.3f", slope, sign, abs(intercept))
    }
}
