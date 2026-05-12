import Foundation

public enum MetadataField: String, Sendable, CaseIterable {
    case format
    case dimensions
    case spacing
    case orientation
    case datatype
    case volumes
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
    public let qformCode: Int
    public let sformCode: Int
    public let orientation: String?

    public init(header: MIQHeader, orientation: String? = nil) {
        dimensions = "\(header.width) x \(header.height) x \(header.depth)"

        let x = header.pixdim[safe: 1] ?? 1
        let y = header.pixdim[safe: 2] ?? 1
        let z = header.pixdim[safe: 3] ?? 1
        spacing = String(format: "%.2f x %.2f x %.2f mm", x, y, z)

        datatype = header.datatype.label
        volumes = header.volumes
        qformCode = header.qformCode
        sformCode = header.sformCode
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
        return entries
    }
}
