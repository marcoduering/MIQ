import Foundation

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

    public func asDisplayLines() -> [String] {
        var lines = [
            "Dimensions: \(dimensions)",
            "Spacing: \(spacing)",
        ]
        if let orientation {
            lines.append("Orientation: \(orientation)")
        }
        lines += [
            "Datatype: \(datatype)",
            "Volumes: \(volumes)"
        ]
        return lines
    }
}