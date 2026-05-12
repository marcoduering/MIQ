import AppKit
import MIQCore

final class MIQPreviewAppKitView: NSView {
    private static let loadingStatusText = "Loading image preview..."

    private let coronal = MIQSliceCanvas(
        imageAlignment: .init(horizontal: .trailing, vertical: .bottom),
        orientation: .placeholderCoronal
    )
    private let sagittal = MIQSliceCanvas(
        imageAlignment: .init(horizontal: .leading, vertical: .bottom),
        orientation: .placeholderSagittal
    )
    private let axial = MIQSliceCanvas(
        imageAlignment: .init(horizontal: .trailing, vertical: .top),
        orientation: .placeholderAxial
    )
    private let metadata = MetadataView()
    private let status = NSTextField(labelWithString: "")
    private var columnRatioConstraint: NSLayoutConstraint?
    private var rowRatioConstraint: NSLayoutConstraint?
    private var metadataEntries: [MetadataEntry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    func showLoading() {
        status.stringValue = Self.loadingStatusText
        status.isHidden = false
    }

    func update(from model: MIQPreviewModel) {
        let showLabels = MIQConfig.showAxisLabels
        let c = MIQConfig.axisLabelColor
        let labelNSColor = NSColor(calibratedRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        coronal.showAxisLabels = showLabels
        sagittal.showAxisLabels = showLabels
        axial.showAxisLabels = showLabels
        coronal.labelColor = labelNSColor
        sagittal.labelColor = labelNSColor
        axial.labelColor = labelNSColor
        coronal.orientation = model.coronalOrientation
        sagittal.orientation = model.sagittalOrientation
        axial.orientation = model.axialOrientation
        coronal.image = model.coronal
        sagittal.image = model.sagittal
        axial.image = model.axial
        updateFOVLayoutRatios()
        metadataEntries = model.metadataEntries
        needsLayout = true

        switch model.state {
        case .failed(let message):
            status.stringValue = "Preview failed: \(message)"
            status.isHidden = false
        case .ready:
            status.isHidden = true
        case .idle, .loading:
            status.stringValue = Self.loadingStatusText
            status.isHidden = false
        }
    }

    override func layout() {
        super.layout()
        refreshMetadataText()
    }

    private func refreshMetadataText() {
        let panelWidth = (bounds.width - 5) * 0.5
        let panelHeight = (bounds.height - 5) * 0.5
        let labelFontSize = max(7, min(13, panelWidth * 0.03))
        coronal.labelFontSize = labelFontSize
        sagittal.labelFontSize = labelFontSize
        axial.labelFontSize = labelFontSize

        guard !metadataEntries.isEmpty else { return }
        let order = MIQConfig.metadataOrder
        let orderIndex: [MetadataField: Int] = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        let sorted = metadataEntries.sorted { a, b in
            let ai = a.field.flatMap { orderIndex[$0] } ?? Int.max
            let bi = b.field.flatMap { orderIndex[$0] } ?? Int.max
            return ai < bi
        }
        let visibleLines = sorted.compactMap { entry -> String? in
            if let field = entry.field, !MIQConfig.showMetadataField(field) { return nil }
            return entry.text
        }
        let fontSize = max(7, min(18, min(panelWidth, panelHeight) * 0.05))
        let inset = max(6, min(24, min(panelWidth, panelHeight) * 0.05))
        metadata.inset = inset
        metadata.attributedText = makeMetadataAttributedString(from: visibleLines, fontSize: fontSize)
    }

    private func buildUI() {
        wantsLayer = true
        #if DEBUG
        layer?.backgroundColor = NSColor.orange.cgColor
        #else
        layer?.backgroundColor = NSColor.black.cgColor
        #endif

        let meta = metadata

        let gridLikeLayout = NSView()
        gridLikeLayout.translatesAutoresizingMaskIntoConstraints = false
        let verticalSplitGuide = NSLayoutGuide()
        let horizontalSplitGuide = NSLayoutGuide()
        gridLikeLayout.addLayoutGuide(verticalSplitGuide)
        gridLikeLayout.addLayoutGuide(horizontalSplitGuide)

        // Keep metadata flexible so it doesn't force a different row geometry.
        meta.setContentHuggingPriority(.defaultLow, for: .horizontal)
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meta.setContentHuggingPriority(.defaultLow, for: .vertical)
        meta.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        coronal.translatesAutoresizingMaskIntoConstraints = false
        sagittal.translatesAutoresizingMaskIntoConstraints = false
        axial.translatesAutoresizingMaskIntoConstraints = false
        meta.translatesAutoresizingMaskIntoConstraints = false
        #if DEBUG
        coronal.debugBorderColor = NSColor(calibratedRed: 1, green: 0.2, blue: 0.2, alpha: 1)
        sagittal.debugBorderColor = NSColor(calibratedRed: 0.2, green: 1, blue: 0.2, alpha: 1)
        axial.debugBorderColor = NSColor(calibratedRed: 0.3, green: 0.6, blue: 1, alpha: 1)
        #endif

        gridLikeLayout.addSubview(coronal)
        gridLikeLayout.addSubview(sagittal)
        gridLikeLayout.addSubview(axial)
        gridLikeLayout.addSubview(meta)

        let columnRatio = coronal.widthAnchor.constraint(equalTo: sagittal.widthAnchor, multiplier: 1.0)
        let rowRatio = axial.heightAnchor.constraint(equalTo: coronal.heightAnchor, multiplier: 1.0)
        self.columnRatioConstraint = columnRatio
        self.rowRatioConstraint = rowRatio

        NSLayoutConstraint.activate([
            verticalSplitGuide.widthAnchor.constraint(equalToConstant: 5),
            verticalSplitGuide.topAnchor.constraint(equalTo: gridLikeLayout.topAnchor),
            verticalSplitGuide.bottomAnchor.constraint(equalTo: gridLikeLayout.bottomAnchor),

            horizontalSplitGuide.heightAnchor.constraint(equalToConstant: 5),
            horizontalSplitGuide.leadingAnchor.constraint(equalTo: gridLikeLayout.leadingAnchor),
            horizontalSplitGuide.trailingAnchor.constraint(equalTo: gridLikeLayout.trailingAnchor),

            coronal.leadingAnchor.constraint(equalTo: gridLikeLayout.leadingAnchor),
            coronal.topAnchor.constraint(equalTo: gridLikeLayout.topAnchor),
            coronal.trailingAnchor.constraint(equalTo: verticalSplitGuide.leadingAnchor),
            coronal.bottomAnchor.constraint(equalTo: horizontalSplitGuide.topAnchor),

            sagittal.leadingAnchor.constraint(equalTo: verticalSplitGuide.trailingAnchor),
            sagittal.topAnchor.constraint(equalTo: gridLikeLayout.topAnchor),
            sagittal.trailingAnchor.constraint(equalTo: gridLikeLayout.trailingAnchor),
            sagittal.bottomAnchor.constraint(equalTo: horizontalSplitGuide.topAnchor),

            axial.leadingAnchor.constraint(equalTo: gridLikeLayout.leadingAnchor),
            axial.topAnchor.constraint(equalTo: horizontalSplitGuide.bottomAnchor),
            axial.trailingAnchor.constraint(equalTo: verticalSplitGuide.leadingAnchor),
            axial.bottomAnchor.constraint(equalTo: gridLikeLayout.bottomAnchor),

            meta.leadingAnchor.constraint(equalTo: verticalSplitGuide.trailingAnchor),
            meta.topAnchor.constraint(equalTo: horizontalSplitGuide.bottomAnchor),
            meta.trailingAnchor.constraint(equalTo: gridLikeLayout.trailingAnchor),
            meta.bottomAnchor.constraint(equalTo: gridLikeLayout.bottomAnchor),

            coronal.heightAnchor.constraint(equalTo: sagittal.heightAnchor),
            axial.heightAnchor.constraint(equalTo: meta.heightAnchor),
            axial.widthAnchor.constraint(equalTo: coronal.widthAnchor),
            meta.widthAnchor.constraint(equalTo: sagittal.widthAnchor),
            columnRatio,
            rowRatio,
        ])

        status.translatesAutoresizingMaskIntoConstraints = false
        status.alignment = .center
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.textColor = NSColor(calibratedWhite: 0.9, alpha: 1.0)
        status.lineBreakMode = .byTruncatingMiddle
        status.maximumNumberOfLines = 2
        status.cell?.wraps = true

        addSubview(gridLikeLayout)
        addSubview(status)

        NSLayoutConstraint.activate([
            gridLikeLayout.leadingAnchor.constraint(equalTo: leadingAnchor),
            gridLikeLayout.trailingAnchor.constraint(equalTo: trailingAnchor),
            gridLikeLayout.topAnchor.constraint(equalTo: topAnchor),
            gridLikeLayout.bottomAnchor.constraint(equalTo: bottomAnchor),
            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
    }

    private func updateFOVLayoutRatios() {
        guard let coronalImage = coronal.image,
              let sagittalImage = sagittal.image,
              let axialImage = axial.image,
              coronalImage.size.width > 0,
              coronalImage.size.height > 0,
              sagittalImage.size.width > 0,
              axialImage.size.height > 0 else {
            return
        }

        // FOV-consistent layout:
        // column ratio = FOVx/FOVy approximated by coronal.width/sagittal.width
        // row ratio = FOVy/FOVz approximated by axial.height/coronal.height
        let desiredColumnRatio = clamp(coronalImage.size.width / sagittalImage.size.width, min: 0.25, max: 4.0)
        let desiredRowRatio = clamp(axialImage.size.height / coronalImage.size.height, min: 0.25, max: 4.0)

        replaceConstraint(
            &columnRatioConstraint,
            with: coronal.widthAnchor.constraint(equalTo: sagittal.widthAnchor, multiplier: desiredColumnRatio)
        )
        replaceConstraint(
            &rowRatioConstraint,
            with: axial.heightAnchor.constraint(equalTo: coronal.heightAnchor, multiplier: desiredRowRatio)
        )

        needsLayout = true
    }

    private func replaceConstraint(_ existing: inout NSLayoutConstraint?, with newConstraint: NSLayoutConstraint) {
        existing?.isActive = false
        existing = newConstraint
        existing?.isActive = true
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        max(minValue, min(maxValue, value))
    }

    private func makeMetadataAttributedString(from lines: [String], fontSize: CGFloat = 15) -> NSAttributedString {
        let labelColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        let valueColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let result = NSMutableAttributedString()

        for (index, line) in lines.enumerated() {
            if let separatorIndex = line.firstIndex(of: ":") {
                let labelPart = String(line[..<line.index(after: separatorIndex)])
                let valuePart = String(line[line.index(after: separatorIndex)...])
                result.append(NSAttributedString(string: labelPart, attributes: [
                    .font: font,
                    .foregroundColor: labelColor
                ]))
                result.append(NSAttributedString(string: valuePart, attributes: [
                    .font: font,
                    .foregroundColor: valueColor
                ]))
            } else {
                result.append(NSAttributedString(string: line, attributes: [
                    .font: font,
                    .foregroundColor: labelColor
                ]))
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .foregroundColor: labelColor
                ]))
            }
        }

        if !MIQConfig.hideDisclaimerInPreview {
            let disclaimerFont = NSFont.systemFont(ofSize: max(6, fontSize * 0.8), weight: .regular)
            let disclaimerColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
            let firstLineStyle = NSMutableParagraphStyle()
            firstLineStyle.paragraphSpacingBefore = fontSize * 6
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

private final class MetadataView: NSView {
    var attributedText: NSAttributedString? { didSet { needsDisplay = true } }
    var inset: CGFloat = 12 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        #if DEBUG
        NSColor.yellow.setStroke()
        let debugBorder = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        debugBorder.lineWidth = 2
        debugBorder.stroke()
        #endif
        guard let text = attributedText else { return }
        text.draw(in: bounds.insetBy(dx: inset, dy: inset))
    }
}
