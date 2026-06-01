import AppKit
import MIQCore

/// Size-responsive typography dials for the preview's metadata panel. File-scoped
/// because this file *is* the whole preview component (the view, `MetadataView`,
/// the scrubber) — so the related scale/clamp triplets are legible side by side
/// and divergence (e.g. a missing `min(w,h)` driver) is obvious at a glance.
/// Geometry-coupled constants whose correctness is relative to surrounding layout
/// stay on their type instead (see `MIQVolumeScrubber`).
private enum Metrics {
    // Resolved size = clamp(min(panelWidth, panelHeight) * scale, min...max).
    static let edgeLabelScale: CGFloat = 0.03
    static let edgeLabelMin: CGFloat = 7
    static let edgeLabelMax: CGFloat = 13

    static let metadataTextScale: CGFloat = 0.045
    static let metadataTextMin: CGFloat = 7
    static let metadataTextMax: CGFloat = 16

    static let insetScale: CGFloat = 0.05
    static let insetMin: CGFloat = 6
    static let insetMax: CGFloat = 24

    // Derived from the resolved metadata font size.
    static let rowSpacingFactor: CGFloat = 0.1
    static let disclaimerFontFactor: CGFloat = 0.8
    static let disclaimerFontMin: CGFloat = 6
    static let disclaimerGapFactor: CGFloat = 2
}

final class MIQPreviewAppKitView: NSView {
    private static let loadingStatusText = "Loading image preview..."

    private struct MetadataRenderInputs {
        let entries: [MetadataEntry]
        let order: [MetadataField]
        let visibility: [Bool]
        let hideDisclaimerInPreview: Bool
        let fontSize: CGFloat
        let inset: CGFloat
        let isFourD: Bool
    }

    var onSliceScrollGestureBegan: (@MainActor () -> Void)?
    var onSliceScroll: (@MainActor (SlicePlane, Int) -> Void)?
    var onSliceVolumeScroll: (@MainActor (Int) -> Void)?
    var onVolumeSeek: (@MainActor (Int) -> Void)?
    var onSliceCursorPosition: (@MainActor (SlicePlane, MIQNormalizedPoint) -> Void)?
    var onSliceWindowAdjust: (@MainActor (CGFloat, CGFloat) -> Void)?

    private let coronal = MIQSliceCanvas(
        plane: .coronal,
        imageAlignment: .init(horizontal: .trailing, vertical: .bottom),
        orientation: .placeholderCoronal
    )
    private let sagittal = MIQSliceCanvas(
        plane: .sagittal,
        imageAlignment: .init(horizontal: .leading, vertical: .bottom),
        orientation: .placeholderSagittal
    )
    private let axial = MIQSliceCanvas(
        plane: .axial,
        imageAlignment: .init(horizontal: .trailing, vertical: .top),
        orientation: .placeholderAxial
    )
    private let metadata = MetadataView()
    private let status = NSTextField(labelWithString: "")
    private var columnRatioConstraint: NSLayoutConstraint?
    private var rowRatioConstraint: NSLayoutConstraint?
    private var metadataEntries: [MetadataEntry] = []
    private var lastMetadataRenderInputs: MetadataRenderInputs?
    private var volumeCount = 1
    private var currentVolumeIndex = 0
    private var volumesExpanding = false
    private var metadataOverlayColor: NSColor = .systemBlue

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    func hideStatus() {
        status.isHidden = true
    }

    func showLoading() {
        status.stringValue = Self.loadingStatusText
        status.isHidden = false
    }

    func update(from model: MIQPreviewModel) {
        let showLabels = MIQConfig.showAxisLabels
        let c = MIQConfig.axisLabelColor
        let labelNSColor = NSColor(calibratedRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)

        applyCanvasUpdate(
            to: coronal,
            image: model.coronal,
            orientation: model.coronalOrientation,
            crosshair: model.crosshairPoint(for: .coronal),
            showAxisLabels: showLabels,
            labelColor: labelNSColor
        )
        applyCanvasUpdate(
            to: sagittal,
            image: model.sagittal,
            orientation: model.sagittalOrientation,
            crosshair: model.crosshairPoint(for: .sagittal),
            showAxisLabels: showLabels,
            labelColor: labelNSColor
        )
        applyCanvasUpdate(
            to: axial,
            image: model.axial,
            orientation: model.axialOrientation,
            crosshair: model.crosshairPoint(for: .axial),
            showAxisLabels: showLabels,
            labelColor: labelNSColor
        )

        updateFOVLayoutRatios()
        if !areMetadataEntriesEqual(metadataEntries, model.metadataEntries) {
            metadataEntries = model.metadataEntries
            lastMetadataRenderInputs = nil
            needsLayout = true
        }

        // 4D-ness can become known *after* the first metadata render (cache-hit
        // path prepares the interactive state asynchronously). When the volume
        // count crosses into 4D, force the structural rebuild so the Volumes
        // line gets reserved blank for the scrubber.
        if model.volumeCount != volumeCount {
            volumeCount = model.volumeCount
            lastMetadataRenderInputs = nil
            needsLayout = true
        }
        currentVolumeIndex = model.currentVolumeIndex
        volumesExpanding = model.isExpandingVolumes
        metadataOverlayColor = labelNSColor
        metadata.setVolumeState(
            index: currentVolumeIndex,
            count: volumeCount,
            expanding: volumesExpanding,
            overlayColor: metadataOverlayColor
        )

        switch model.state {
        case .failed(let message):
            status.stringValue = "Preview failed: \(message)"
            status.isHidden = false
        case .ready:
            status.isHidden = true
        case .idle, .loading:
            break
        }
    }

    override func layout() {
        super.layout()
        refreshMetadataText()
    }

    private func refreshMetadataText() {
        let panelWidth = (bounds.width - 5) * 0.5
        let panelHeight = (bounds.height - 5) * 0.5
        let minPanelExtent = min(panelWidth, panelHeight)
        let labelFontSize = clamp(minPanelExtent * Metrics.edgeLabelScale, min: Metrics.edgeLabelMin, max: Metrics.edgeLabelMax)
        applyLabelFontSize(labelFontSize)

        let order = MIQConfig.metadataOrder
        let visibility = MetadataField.allCases.map(MIQConfig.showMetadataField)
        let fontSize = clamp(minPanelExtent * Metrics.metadataTextScale, min: Metrics.metadataTextMin, max: Metrics.metadataTextMax)
        let inset = clamp(minPanelExtent * Metrics.insetScale, min: Metrics.insetMin, max: Metrics.insetMax)
        let isFourD = volumeCount > 1
        let inputs = MetadataRenderInputs(
            entries: metadataEntries,
            order: order,
            visibility: visibility,
            hideDisclaimerInPreview: MIQConfig.hideDisclaimerInPreview,
            fontSize: fontSize,
            inset: inset,
            isFourD: isFourD
        )

        // Skip metadata sort/rebuild unless metadata inputs or panel metrics changed.
        if let lastMetadataRenderInputs,
           areMetadataRenderInputsEqual(lastMetadataRenderInputs, inputs) {
            return
        }

        lastMetadataRenderInputs = inputs

        guard !metadataEntries.isEmpty else {
            if metadata.attributedText != nil {
                metadata.attributedText = nil
            }
            return
        }

        let orderIndex: [MetadataField: Int] = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        let sorted = metadataEntries.sorted { a, b in
            let ai = a.field.flatMap { orderIndex[$0] } ?? Int.max
            let bi = b.field.flatMap { orderIndex[$0] } ?? Int.max
            return ai < bi
        }

        // Build the drawn lines. For a 4D file the visible Volumes line is
        // replaced by an empty line of identical height: the scrubber overlays
        // exactly that slot, every other line keeps its position, and the value
        // still renders (live, in overlay colour) inside the scrubber instead.
        var lines: [String] = []
        var volumesLineIndex: Int?
        for entry in sorted {
            if let field = entry.field, !MIQConfig.showMetadataField(field) { continue }
            if isFourD, entry.field == .volumes {
                volumesLineIndex = lines.count
                lines.append("")
            } else {
                lines.append(entry.text)
            }
        }

        if abs(metadata.inset - inset) > 0.001 {
            metadata.inset = inset
        }
        metadata.volumesLineIndex = volumesLineIndex
        metadata.lineFont = volumesLineIndex == nil
            ? nil
            : NSFont.systemFont(ofSize: fontSize, weight: .regular)
        // The metadata panel shares the sagittal panel's x-range, so the
        // sagittal image's right edge is usable verbatim as the scrubber limit.
        metadata.scrubberRightLimit = sagittal.renderedImageRightEdge
        metadata.attributedText = makeMetadataAttributedString(from: lines, fontSize: fontSize)
        // Reflect the now-known reserved slot immediately so the scrubber shows
        // on first paint of a 4D file (not only after the next model change).
        metadata.setVolumeState(
            index: currentVolumeIndex,
            count: volumeCount,
            expanding: volumesExpanding,
            overlayColor: metadataOverlayColor
        )
    }

    private func buildUI() {
        wantsLayer = true
        #if DEBUG
        layer?.backgroundColor = MIQConfig.debugShowLayoutBorders
            ? NSColor.orange.cgColor
            : NSColor.black.cgColor
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

        coronal.onScrollGestureBegan = { [weak self] in self?.onSliceScrollGestureBegan?() }
        sagittal.onScrollGestureBegan = { [weak self] in self?.onSliceScrollGestureBegan?() }
        axial.onScrollGestureBegan = { [weak self] in self?.onSliceScrollGestureBegan?() }

        coronal.onScroll = { [weak self] plane, step in
            self?.onSliceScroll?(plane, step)
        }
        sagittal.onScroll = { [weak self] plane, step in
            self?.onSliceScroll?(plane, step)
        }
        axial.onScroll = { [weak self] plane, step in
            self?.onSliceScroll?(plane, step)
        }

        coronal.onVolumeScroll = { [weak self] step in self?.onSliceVolumeScroll?(step) }
        sagittal.onVolumeScroll = { [weak self] step in self?.onSliceVolumeScroll?(step) }
        axial.onVolumeScroll = { [weak self] step in self?.onSliceVolumeScroll?(step) }

        metadata.onVolumeSeek = { [weak self] index in self?.onVolumeSeek?(index) }
        metadata.onScrollGestureBegan = { [weak self] in self?.onSliceScrollGestureBegan?() }
        metadata.onVolumeScroll = { [weak self] step in self?.onSliceVolumeScroll?(step) }

        coronal.onCursorPosition = { [weak self] plane, point in
            self?.onSliceCursorPosition?(plane, point)
        }
        sagittal.onCursorPosition = { [weak self] plane, point in
            self?.onSliceCursorPosition?(plane, point)
        }
        axial.onCursorPosition = { [weak self] plane, point in
            self?.onSliceCursorPosition?(plane, point)
        }

        coronal.onWindowAdjust = { [weak self] dx, dy in self?.onSliceWindowAdjust?(dx, dy) }
        sagittal.onWindowAdjust = { [weak self] dx, dy in self?.onSliceWindowAdjust?(dx, dy) }
        axial.onWindowAdjust = { [weak self] dx, dy in self?.onSliceWindowAdjust?(dx, dy) }

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
        let epsilon: CGFloat = 0.001

        var didUpdateConstraint = false

        if abs((columnRatioConstraint?.multiplier ?? 0) - desiredColumnRatio) > epsilon {
            replaceConstraint(
                &columnRatioConstraint,
                with: coronal.widthAnchor.constraint(equalTo: sagittal.widthAnchor, multiplier: desiredColumnRatio)
            )
            didUpdateConstraint = true
        }

        if abs((rowRatioConstraint?.multiplier ?? 0) - desiredRowRatio) > epsilon {
            replaceConstraint(
                &rowRatioConstraint,
                with: axial.heightAnchor.constraint(equalTo: coronal.heightAnchor, multiplier: desiredRowRatio)
            )
            didUpdateConstraint = true
        }

        if didUpdateConstraint {
            needsLayout = true
        }
    }

    private func areMetadataEntriesEqual(_ lhs: [MetadataEntry], _ rhs: [MetadataEntry]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.field == right.field && left.text == right.text
        }
    }

    private func areMetadataRenderInputsEqual(_ lhs: MetadataRenderInputs, _ rhs: MetadataRenderInputs) -> Bool {
        areMetadataEntriesEqual(lhs.entries, rhs.entries) &&
        lhs.order == rhs.order &&
        lhs.visibility == rhs.visibility &&
        lhs.hideDisclaimerInPreview == rhs.hideDisclaimerInPreview &&
        abs(lhs.fontSize - rhs.fontSize) <= 0.001 &&
        abs(lhs.inset - rhs.inset) <= 0.001 &&
        lhs.isFourD == rhs.isFourD
    }

    private func applyLabelFontSize(_ size: CGFloat) {
        if abs(coronal.labelFontSize - size) > 0.001 {
            coronal.labelFontSize = size
        }
        if abs(sagittal.labelFontSize - size) > 0.001 {
            sagittal.labelFontSize = size
        }
        if abs(axial.labelFontSize - size) > 0.001 {
            axial.labelFontSize = size
        }
    }

    private func applyCanvasUpdate(
        to canvas: MIQSliceCanvas,
        image: NSImage?,
        orientation: SliceOrientationLabels,
        crosshair: MIQNormalizedPoint?,
        showAxisLabels: Bool,
        labelColor: NSColor
    ) {
        if canvas.showAxisLabels != showAxisLabels {
            canvas.showAxisLabels = showAxisLabels
        }

        if !areColorsEqual(canvas.labelColor, labelColor) {
            canvas.labelColor = labelColor
        }

        if !areOrientationLabelsEqual(canvas.orientation, orientation) {
            canvas.orientation = orientation
        }

        if !areImagesIdentical(canvas.image, image) {
            canvas.image = image
        }

        if canvas.crosshair != crosshair {
            canvas.crosshair = crosshair
        }
    }

    private func areColorsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        lhs.isEqual(rhs)
    }

    private func areOrientationLabelsEqual(_ lhs: SliceOrientationLabels, _ rhs: SliceOrientationLabels) -> Bool {
        lhs.leading == rhs.leading &&
        lhs.trailing == rhs.trailing &&
        lhs.top == rhs.top &&
        lhs.bottom == rhs.bottom &&
        lhs.isUnknown == rhs.isUnknown
    }

    private func areImagesIdentical(_ lhs: NSImage?, _ rhs: NSImage?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(left), .some(right)):
            return left === right
        default:
            return false
        }
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
        // Breathing room between rows. Trailing (not leading) spacing keeps each
        // line's glyphs at its fragment top, so the scrubber — drawn at its
        // fragment top — still aligns with its neighbours.
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.paragraphSpacing = fontSize * Metrics.rowSpacingFactor
        let result = NSMutableAttributedString()

        for (index, line) in lines.enumerated() {
            if let separatorIndex = line.firstIndex(of: ":") {
                let labelPart = String(line[..<line.index(after: separatorIndex)])
                let valuePart = String(line[line.index(after: separatorIndex)...])
                result.append(NSAttributedString(string: labelPart, attributes: [
                    .font: font,
                    .foregroundColor: labelColor,
                    .paragraphStyle: rowStyle
                ]))
                result.append(NSAttributedString(string: valuePart, attributes: [
                    .font: font,
                    .foregroundColor: valueColor,
                    .paragraphStyle: rowStyle
                ]))
            } else {
                result.append(NSAttributedString(string: line, attributes: [
                    .font: font,
                    .foregroundColor: labelColor,
                    .paragraphStyle: rowStyle
                ]))
            }

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .foregroundColor: labelColor,
                    .paragraphStyle: rowStyle
                ]))
            }
        }

        if !MIQConfig.hideDisclaimerInPreview {
            let disclaimerFont = NSFont.systemFont(ofSize: max(Metrics.disclaimerFontMin, fontSize * Metrics.disclaimerFontFactor), weight: .regular)
            let disclaimerColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
            let firstLineStyle = NSMutableParagraphStyle()
            firstLineStyle.paragraphSpacingBefore = fontSize * Metrics.disclaimerGapFactor
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
    // Own TextKit stack: the glyphs are drawn AND the scrubber is positioned
    // from the same layout manager, so the reserved Volumes line sits on
    // exactly the baseline its neighbours do — no separate line-height estimate
    // that can drift against NSAttributedString.draw(in:).
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()

    var attributedText: NSAttributedString? {
        didSet {
            textStorage.setAttributedString(attributedText ?? NSAttributedString())
            needsDisplay = true
            needsLayout = true
        }
    }
    var inset: CGFloat = 12 { didSet { needsDisplay = true; needsLayout = true } }

    /// Index (within the drawn metadata lines) of the line reserved blank for
    /// the 4D scrubber, or `nil` for 3D files / hidden Volumes field. The owner
    /// guarantees that line is empty in `attributedText` so the scrubber sits
    /// exactly where "Volumes:" would have rendered.
    var volumesLineIndex: Int? { didSet { needsLayout = true } }
    var lineFont: NSFont? { didSet { needsLayout = true } }
    /// Right edge (this view's x coordinates) the scrubber must not exceed —
    /// the sagittal image's right edge. The metadata panel shares the sagittal
    /// panel's x-range, so the value is used directly. `nil` ⇒ full width.
    var scrubberRightLimit: CGFloat? { didSet { needsLayout = true } }
    var onVolumeSeek: (@MainActor (Int) -> Void)? {
        didSet { scrubber.onScrub = onVolumeSeek }
    }
    /// Option-scroll over the metadata panel also steps the 4th axis, with the
    /// same momentum/latch semantics as the slice canvases.
    var onVolumeScroll: (@MainActor (Int) -> Void)?
    var onScrollGestureBegan: (@MainActor () -> Void)?
    private var scrollResolver = ScrollStepResolver()

    private let scrubber = MIQVolumeScrubber()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextKit()
        scrubber.isHidden = true
        addSubview(scrubber)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTextKit()
        scrubber.isHidden = true
        addSubview(scrubber)
    }

    private func configureTextKit() {
        textContainer.lineFragmentPadding = 0   // flush-left, like the old draw(in:)
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    private func syncContainer() {
        textContainer.size = CGSize(
            width: max(0, bounds.width - 2 * inset),
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
    }

    /// Character index where the `index`-th line begins (counting "\n"s).
    ///
    /// Invariant: this assumes `attributedText` is the `makeMetadataAttributedString`
    /// output — one metadata row per paragraph, rows joined by a single "\n",
    /// the reserved 4D row an empty string. The scrubber's position depends on
    /// it; if that builder ever stops being newline-joined (e.g. switches to
    /// paragraph breaks or inserts blank separator lines) this mapping — and the
    /// scrubber overlay — silently breaks.
    private func characterIndexForLine(_ index: Int) -> Int {
        let ns = textStorage.string as NSString
        var charIdx = 0
        var line = 0
        while line < index, charIdx < ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: charIdx, length: ns.length - charIdx))
            if r.location == NSNotFound { break }
            charIdx = r.location + 1
            line += 1
        }
        return min(charIdx, max(0, ns.length - 1))
    }

    /// Line fragment rect the scrubber must align to for the reserved (empty)
    /// Volumes line.
    ///
    /// The reservation is an empty string. When it is also the *final* paragraph
    /// (no Scaling row after it AND the disclaimer is hidden, so nothing trails
    /// it) it has no glyphs of its own — TextKit represents it as the layout
    /// manager's *extra* line fragment rather than a normal one. In that case
    /// `characterIndexForLine` clamps back to the previous line's terminating
    /// newline, so the glyph-based rect would seat the scrubber on the line
    /// *above* Volumes and hide it. The extra line fragment exists for this
    /// builder's output only in exactly that trailing-empty-Volumes case (every
    /// non-empty last line ends without a newline), so prefer it when present.
    private func reservedLineFragmentRect(_ index: Int) -> CGRect {
        if layoutManager.extraLineFragmentTextContainer != nil {
            return layoutManager.extraLineFragmentRect
        }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndexForLine(index))
        return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    }

    /// Cheap per-frame update: only the live index / expanding flag / colour.
    /// Deliberately does NOT touch `attributedText` so a scrub never re-runs the
    /// throttled metadata sort/rebuild.
    func setVolumeState(index: Int, count: Int, expanding: Bool, overlayColor: NSColor) {
        scrubber.configure(index: index, count: count, expanding: expanding, overlayColor: overlayColor)
        scrubber.isHidden = volumesLineIndex == nil || count <= 1
    }

    override func layout() {
        super.layout()
        guard let index = volumesLineIndex, textStorage.length > 0 else {
            scrubber.isHidden = true
            return
        }
        syncContainer()
        if let font = lineFont { scrubber.font = font }
        let fragment = reservedLineFragmentRect(index)
        let originX = inset + fragment.minX
        let fullWidth = bounds.width - inset - originX
        let limitedWidth = scrubberRightLimit.map { $0 - originX } ?? fullWidth
        scrubber.frame = CGRect(
            x: originX,
            y: inset + fragment.minY,
            width: max(0, min(fullWidth, limitedWidth)),
            height: fragment.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        #if DEBUG
        if MIQConfig.debugShowLayoutBorders {
            NSColor.yellow.setStroke()
            let debugBorder = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            debugBorder.lineWidth = 2
            debugBorder.stroke()
        }
        #endif
        guard textStorage.length > 0 else { return }
        syncContainer()
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: inset, y: inset))
    }

    override func scrollWheel(with event: NSEvent) {
        // The metadata panel has no slice axis; only Option-scroll (the 4D
        // axis) acts here. Everything else is swallowed by the resolver.
        guard let outcome = scrollResolver.resolve(ScrollStepInput(event), onBegan: { [weak self] in
            self?.onScrollGestureBegan?()
        }), outcome.axis == .volume else { return }
        onVolumeScroll?(outcome.step)
    }
}

/// Inline 4D timepoint indicator + scrubber, drawn over the reserved "Volumes:"
/// metadata line. The label stays metadata-gray (matches its siblings); the
/// live readout and track use the user overlay colour so the only coloured,
/// interactive token in an otherwise grey pane reads as "touch me".
private final class MIQVolumeScrubber: NSView {
    var onScrub: (@MainActor (Int) -> Void)?
    private(set) var overlayColor: NSColor = .systemBlue
    var font: NSFont = .systemFont(ofSize: 13, weight: .regular) { didSet { needsDisplay = true } }

    private var index = 0
    private var count = 1
    private var expanding = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Single change-gated entry point. Returns early when nothing visible
    /// changed so a pure x/y/z slice scroll (same timepoint, same colour) never
    /// repaints the scrubber.
    func configure(index: Int, count: Int, expanding: Bool, overlayColor: NSColor) {
        let colorChanged = !overlayColor.isEqual(self.overlayColor)
        guard index != self.index
            || count != self.count
            || expanding != self.expanding
            || colorChanged else { return }
        self.index = index
        self.count = count
        self.expanding = expanding
        self.overlayColor = overlayColor
        needsDisplay = true
    }

    private static let labelColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)

    // Geometry dials. Kept here (not in the file-scoped `Metrics`) because each
    // is only meaningful next to the formula it feeds — `valueToTrackGap` only
    // makes sense beside `labelW + widestValue`, the knob ratios only relative
    // to `lineH`. Naming buys the documentation; locality keeps the rationale.
    private static let valueToTrackGap: CGFloat = 5      // after the "N / N" readout
    private static let trackTrailingInset: CGFloat = 10  // track right-edge inset
    private static let minTrackWidth: CGFloat = 12       // hide the track below this
    private static let seekHitSlop: CGFloat = 6          // mouseDown grace left of track
    private static let trackThicknessFactor: CGFloat = 0.16
    private static let trackThicknessMin: CGFloat = 3
    private static let knobWidthFactor: CGFloat = 1.0
    private static let knobHeightFactor: CGFloat = 0.5

    /// Same formula `NSLayoutManager.defaultLineHeight(for:)` uses internally,
    /// without allocating a fresh layout manager per call (this is on the
    /// scrub-drag input path).
    private static func defaultLineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// Horizontal extent of the draggable track. The reservation uses the
    /// *widest* readout ("N / N"), NOT the live value, so the track origin
    /// stays fixed as the digit count changes mid-drag (otherwise the x→volume
    /// mapping wobbled under the cursor). `count` is constant per file, so this
    /// is stable for the whole gesture. Insets account for the knob's
    /// half-width on each side so the pill never overlaps the value text or
    /// the view's right edge when seated at the track ends. `nil` when there
    /// is no room.
    private func trackRange() -> (minX: CGFloat, maxX: CGFloat)? {
        let labelW = ("Volumes: " as NSString).size(withAttributes: [.font: font]).width
        let widestValue = ("\(count) / \(count)" as NSString).size(withAttributes: [.font: font]).width
        let lineH = min(bounds.height, Self.defaultLineHeight(for: font))
        let knobHalfW = lineH * Self.knobWidthFactor / 2
        let minX = labelW + widestValue + Self.valueToTrackGap + knobHalfW
        let maxX = bounds.width - Self.trackTrailingInset - knobHalfW
        guard maxX - minX >= Self.minTrackWidth, count > 1 else { return nil }
        return (minX, maxX)
    }

    private func valueString() -> String {
        let base = "\(index + 1) / \(count)"
        return expanding ? base + "  decompressing…" : base
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        // The fragment height includes the row's trailing paragraph spacing, so
        // the visible text occupies only the top ~line-height. Centre the track
        // on that text band, not the padded fragment, so it tracks the label.
        let lineH = min(bounds.height, Self.defaultLineHeight(for: font))
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.labelColor]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: overlayColor]
        let label = "Volumes: " as NSString
        let value = valueString() as NSString
        // Draw at the frame's top, NOT vertically centred: the frame top is
        // already the sibling line's fragment top (inset + index ×
        // defaultLineHeight), and NSString.draw(at:) shares the default line
        // metrics of NSAttributedString.draw(in:), so y = 0 lands exactly where
        // TextKit drew the lines above and below.
        let labelWidth = label.size(withAttributes: labelAttrs).width
        label.draw(at: CGPoint(x: 0, y: 0), withAttributes: labelAttrs)
        value.draw(at: CGPoint(x: labelWidth, y: 0), withAttributes: valueAttrs)

        guard let track = trackRange() else { return }
        let centerY = lineH / 2
        let thickness = max(Self.trackThicknessMin, lineH * Self.trackThicknessFactor)
        let trackRect = CGRect(x: track.minX, y: centerY - thickness / 2, width: track.maxX - track.minX, height: thickness)
        let radius = thickness / 2
        let dim: CGFloat = expanding ? 0.5 : 1.0

        overlayColor.withAlphaComponent(0.20 * dim).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()

        let fraction = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
        let knobX = track.minX + fraction * (track.maxX - track.minX)

        let filled = CGRect(x: track.minX, y: trackRect.minY, width: knobX - track.minX, height: thickness)
        overlayColor.withAlphaComponent(0.60 * dim).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()

        let knobW = lineH * Self.knobWidthFactor
        let knobH = lineH * Self.knobHeightFactor
        let knob = CGRect(x: knobX - knobW / 2, y: centerY - knobH / 2, width: knobW, height: knobH)
        let knobRadius = knobH / 2
        overlayColor.withAlphaComponent(dim).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knobRadius, yRadius: knobRadius).fill()
    }

    private var isScrubbing = false

    override func mouseDown(with event: NSEvent) {
        guard count > 1, let track = trackRange() else { return }
        let x = convert(event.locationInWindow, from: nil).x
        // The minX guard belongs ONLY here: a click on the "Volumes: n / N"
        // text must not seek. Once a scrub starts, drags are clamped instead.
        guard x >= track.minX - Self.seekHitSlop else { isScrubbing = false; return }
        isScrubbing = true
        applySeek(x: x, track: track)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isScrubbing, count > 1, let track = trackRange() else { return }
        // No minX guard: a fast drag (and AppKit still delivers mouseDragged
        // here even when the cursor leaves the view) must clamp to the track
        // ends — dragging left has to reach volume 1, not freeze partway.
        applySeek(x: convert(event.locationInWindow, from: nil).x, track: track)
    }

    override func mouseUp(with event: NSEvent) {
        isScrubbing = false
    }

    private func applySeek(x: CGFloat, track: (minX: CGFloat, maxX: CGFloat)) {
        let span = track.maxX - track.minX
        guard span > 0 else { return }
        let clamped = min(track.maxX, max(track.minX, x))
        let fraction = (clamped - track.minX) / span
        let target = Int((fraction * CGFloat(count - 1)).rounded())
        if target != index { onScrub?(target) }
    }
}
