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
    /// The header's free-text description (`MIQHeader.comment`). Off by default:
    /// usually empty or a tool stamp, but useful for spotting files that carry
    /// patient data (MRtrix copies DICOM patient fields into MIF comments).
    case comment
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
    public let comment: String?

    /// Multiplication sign, not the letter x.
    private static let separator = "\u{00D7}"

    public init(header: MIQHeader, orientation: String? = nil) {
        let sep = " \(Self.separator) "
        dimensions = "\(header.width)\(sep)\(header.height)\(sep)\(header.depth)"

        let x = header.pixdim[safe: 1] ?? 1
        let y = header.pixdim[safe: 2] ?? 1
        let z = header.pixdim[safe: 3] ?? 1
        spacing = String(format: "%.2f\(sep)%.2f\(sep)%.2f mm", x, y, z)

        datatype = header.datatypeLabel ?? header.datatype.label
        volumes = header.volumes
        sclSlope = header.sclSlope
        sclInter = header.sclInter
        self.orientation = orientation
        comment = header.comment.map(Self.displayComment)
    }

    /// At most this many comment lines are shown, plus a "…" line when cut. The
    /// preview applies the same limit again to *wrapped* lines, which only it can
    /// measure (`MetadataPanelText.fitValue`).
    public static let maxCommentLines = 3

    /// Caps the comment to `maxCommentLines` lines, adding a "…" line after them
    /// when there are more (on its own line, since an ellipsis at the end of a line
    /// reads as part of the text). Lines are joined with U+2028 (line separator) so
    /// the comment stays one paragraph: the panel counts "\n"-separated rows to seat
    /// its overlays, and a line separator keeps the value column's hanging indent
    /// on every line.
    static func displayComment(_ comment: String) -> String {
        let lines = comment.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var shown = Array(lines.prefix(maxCommentLines))
        if lines.count > maxCommentLines { shown.append("\u{2026}") }
        return shown.joined(separator: "\u{2028}")
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
        if let comment {
            entries.append(MetadataEntry(field: .comment, label: "Comment", value: comment))
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

        // A zero intercept contributes nothing — "x 2 + 0" is just noise, so the
        // term is dropped and the row reads "x 2". Only the identity case above
        // hides the row entirely.
        guard abs(intercept) > epsilon else {
            return String(format: "\(Self.separator) %.6g", slope)
        }

        let sign = intercept < 0 ? "-" : "+"
        return String(format: "\(Self.separator) %.6g %@ %.6g", slope, sign, abs(intercept))
    }
}
