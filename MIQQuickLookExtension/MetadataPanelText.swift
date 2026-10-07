import AppKit
import MIQCore

/// What the preview's metadata panel says and how its text looks: row order and
/// visibility, the reserved Volumes / voxel-value slots, the two-column layout
/// and the disclaimer footer. Shared with the app (like `MIQImageBridge`) so the
/// Settings window's panel preview is the real panel text, not a look-alike.
///
/// Every setting is an input — nothing here reads `MIQConfig` — so the preview
/// passes what it reads from the App Group and Settings passes its live values.
/// Sizing (font size, inset) stays with the caller: the preview scales it with
/// the panel, Settings uses a fixed size.
enum MetadataPanelText {
    // Derived from the resolved metadata font size.
    static let rowSpacingFactor: CGFloat = 0.3
    static let labelGutterFactor: CGFloat = 0.9
    static let disclaimerFontFactor: CGFloat = 0.8
    static let disclaimerFontMin: CGFloat = 6
    static let disclaimerGapFactor: CGFloat = 2

    /// Labels drawn by the preview's overlays rather than by the text, still
    /// measured when sizing the label column.
    static let volumesRowLabel = "Volumes"
    static let valueRowLabel = "Voxel value"

    /// One drawn line: label + value, empty for an overlay-drawn row (Volumes,
    /// voxel value), value-only for a row that spans the panel (the debug build
    /// stamp).
    struct Row {
        let label: String
        let value: String
    }

    struct Layout {
        let rows: [Row]
        /// Line reserved blank for the 4D scrubber, if any.
        let volumesLineIndex: Int?
        /// Line reserved blank for the live voxel-value readout, if any.
        let valueLineIndex: Int?
    }

    /// Orders and filters `entries` into drawn rows.
    ///
    /// - Parameters:
    ///   - showsValue: whether the live voxel-value line occupies a slot (the
    ///     crosshair is visible and the field enabled); the slot is reserved
    ///     blank for the overlay.
    ///   - staticValueText: instead of a reserved slot, draw the voxel-value row
    ///     as ordinary text with this value (Settings' sample). The preview never
    ///     sets it.
    static func layout(
        entries: [MetadataEntry],
        order: [MetadataField],
        isVisible: (MetadataField) -> Bool,
        isFourD: Bool,
        showsValue: Bool,
        staticValueText: String? = nil
    ) -> Layout {
        let orderIndex: [MetadataField: Int] = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        // The value field carries no header-derived text — inject an entry so it
        // takes its configured order position. In the preview its slot is
        // reserved blank below and the overlay draws both halves, so nothing from
        // here is ever shown (and it never churns the rebuild).
        var entries = entries
        if let staticValueText {
            entries.append(MetadataEntry(field: .value, label: valueRowLabel, value: staticValueText))
        } else if showsValue {
            entries.append(MetadataEntry(field: .value, label: "", value: ""))
        }
        let sorted = entries.sorted { a, b in
            let ai = a.field.flatMap { orderIndex[$0] } ?? Int.max
            let bi = b.field.flatMap { orderIndex[$0] } ?? Int.max
            return ai < bi
        }

        // The 4D Volumes line and the live Value line are each reserved as an
        // empty line of identical height: the matching overlay draws over exactly
        // that slot, every other line keeps its position. For the Volumes case
        // the live value renders inside the scrubber instead.
        var rows: [Row] = []
        var volumesLineIndex: Int?
        var valueLineIndex: Int?
        for entry in sorted {
            if let field = entry.field, !isVisible(field) { continue }
            if isFourD, entry.field == .volumes {
                volumesLineIndex = rows.count
                rows.append(Row(label: "", value: ""))
            } else if entry.field == .value, staticValueText == nil {
                valueLineIndex = rows.count
                rows.append(Row(label: "", value: ""))
            } else if entry.field == nil {
                // Not a configurable field (only the debug build stamp): span the
                // panel rather than joining the column, whose width it would
                // otherwise drive — "DEBUG BUILD" is wider than any shipping label,
                // so a Debug build would misrepresent Release geometry.
                rows.append(Row(label: "", value: entry.text))
            } else {
                rows.append(Row(label: entry.label, value: entry.value))
            }
        }
        return Layout(rows: rows, volumesLineIndex: volumesLineIndex, valueLineIndex: valueLineIndex)
    }

    /// The voxel-value readout's text: integers without a decimal point, other
    /// values to six significant digits.
    static func formatVoxelValue(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "+Inf" }
        if value == value.rounded(), abs(value) < 1e7 {
            return String(Int(value))
        }
        return String(format: "%.6g", Double(value))
    }

    /// Value-column x: widest label plus a gutter. Empty labels are skipped.
    static func labelColumnOrigin(for labels: [String], font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widest = labels.reduce(CGFloat.zero) { widest, label in
            guard !label.isEmpty else { return widest }
            return max(widest, (label as NSString).size(withAttributes: attributes).width)
        }
        return widest + font.pointSize * labelGutterFactor
    }

    static func attributedString(
        from rows: [Row],
        fontSize: CGFloat,
        labelColumnX: CGFloat,
        showsDisclaimer: Bool
    ) -> NSAttributedString {
        let labelColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        let valueColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        // Breathing room between rows. Trailing (not leading) spacing keeps each
        // line's glyphs at its fragment top, so the scrubber — drawn at its
        // fragment top — still aligns with its neighbours.
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.paragraphSpacing = fontSize * rowSpacingFactor
        // Two columns, one tab apart; `headIndent` hangs a wrapped value.
        rowStyle.tabStops = [NSTextTab(textAlignment: .left, location: labelColumnX)]
        rowStyle.defaultTabInterval = labelColumnX
        rowStyle.headIndent = labelColumnX
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor,
            .paragraphStyle: rowStyle
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: valueColor,
            .paragraphStyle: rowStyle
        ]
        let result = NSMutableAttributedString()

        for (index, row) in rows.enumerated() {
            if !row.label.isEmpty {
                result.append(NSAttributedString(string: row.label + "\t", attributes: labelAttrs))
            }
            if !row.value.isEmpty {
                result.append(NSAttributedString(string: row.value, attributes: valueAttrs))
            }

            if index < rows.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: labelAttrs))
            }
        }

        if showsDisclaimer {
            let disclaimerFont = NSFont.systemFont(ofSize: max(disclaimerFontMin, fontSize * disclaimerFontFactor), weight: .regular)
            let disclaimerColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
            let firstLineStyle = NSMutableParagraphStyle()
            firstLineStyle.paragraphSpacingBefore = fontSize * disclaimerGapFactor
            let firstLineAttrs: [NSAttributedString.Key: Any] = [
                .font: disclaimerFont,
                .foregroundColor: disclaimerColor,
                .paragraphStyle: firstLineStyle
            ]
            let secondLineAttrs: [NSAttributedString.Key: Any] = [
                .font: disclaimerFont,
                .foregroundColor: disclaimerColor
            ]
            result.append(NSAttributedString(string: "\nNot for clinical or diagnostic use.", attributes: firstLineAttrs))
            result.append(NSAttributedString(string: "\nNo warranty expressed or implied.", attributes: secondLineAttrs))
        }

        return result
    }
}
