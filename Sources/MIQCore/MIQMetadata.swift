import Foundation

public enum MetadataField: String, Sendable, CaseIterable {
    case format
    case dimensions
    case spacing
    case orientation
    case datatype
    case volumes
    case scaling
    /// Live intensity at the crosshair voxel. Unlike every other field this is
    /// not derived from the header at parse time — it is injected by the preview
    /// only while the user is interacting (the crosshair is visible) and its
    /// value updates per cursor move. It therefore never appears in
    /// `asDisplayLines()`; the preview reserves its slot and draws the value.
    case value
}

/// One metadata row. Split, because the preview's two-column panel needs each
/// label's rendered width; `text` is the joined form.
public struct MetadataEntry: Sendable {
    public let field: MetadataField?
    public let label: String
    public let value: String

    public var text: String {
        label.isEmpty ? value : "\(label): \(value)"
    }

    public init(field: MetadataField?, label: String, value: String) {
        self.field = field
        self.label = label
        self.value = value
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

    /// Multiplication sign, not the letter x.
    private static let separator = "\u{00D7}"

    public init(header: MIQHeader, orientation: String? = nil) {
        let sep = " \(Self.separator) "
        dimensions = "\(header.width)\(sep)\(header.height)\(sep)\(header.depth)"

        let x = header.pixdim[safe: 1] ?? 1
        let y = header.pixdim[safe: 2] ?? 1
        let z = header.pixdim[safe: 3] ?? 1
        spacing = String(format: "%.2f\(sep)%.2f\(sep)%.2f mm", x, y, z)

        datatype = header.datatype.label
        volumes = header.volumes
        sclSlope = header.sclSlope
        sclInter = header.sclInter
        self.orientation = orientation
    }

    public func asDisplayLines() -> [MetadataEntry] {
        var entries: [MetadataEntry] = [
            MetadataEntry(field: .dimensions, label: "Dimensions", value: dimensions),
            MetadataEntry(field: .spacing, label: "Spacing", value: spacing),
        ]
        if let orientation {
            entries.append(MetadataEntry(field: .orientation, label: "Orientation", value: orientation))
        }
        entries.append(MetadataEntry(field: .datatype, label: "Datatype", value: datatype))
        entries.append(MetadataEntry(field: .volumes, label: "Volumes", value: "\(volumes)"))
        if let scaling {
            entries.append(MetadataEntry(field: .scaling, label: "Scaling", value: scaling))
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
        return String(format: "\(Self.separator) %.6g %@ %.6g", slope, sign, abs(intercept))
    }
}
