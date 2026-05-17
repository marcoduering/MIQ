import AppKit
import MIQCore

extension ScrollStepInput {
    /// Map an `NSEvent` to the AppKit-free input the resolver consumes.
    init(_ event: NSEvent) {
        self.init(
            optionHeld: event.modifierFlags.contains(.option),
            phaseBegan: event.phase.contains(.began),
            isLegacyWheel: event.phase == [] && event.momentumPhase == [],
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
    }
}

final class MIQSliceCanvas: NSView {
    enum HorizontalImageAlignment {
        case leading
        case trailing
    }

    enum VerticalImageAlignment {
        case top
        case bottom
    }

    struct ImageAlignment {
        let horizontal: HorizontalImageAlignment
        let vertical: VerticalImageAlignment
    }

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var orientation: SliceOrientationLabels {
        didSet { needsDisplay = true }
    }

    var labelFontSize: CGFloat = 11 {
        didSet { needsDisplay = true }
    }

    var showAxisLabels: Bool = true {
        didSet { needsDisplay = true }
    }

    var labelColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    var crosshair: MIQNormalizedPoint? {
        didSet { needsDisplay = true }
    }

    var onScrollGestureBegan: (@MainActor () -> Void)?
    var onScroll: (@MainActor (SlicePlane, Int) -> Void)?
    /// Option-modifier scroll: step the 4th (volume/time) axis instead of the
    /// in-plane slice. Plane-agnostic — the 4th axis is not spatial.
    var onVolumeScroll: (@MainActor (Int) -> Void)?
    var onCursorPosition: (@MainActor (SlicePlane, MIQNormalizedPoint) -> Void)?
    var onWindowAdjust: (@MainActor (CGFloat, CGFloat) -> Void)?

    private let plane: SlicePlane
    private let imageAlignment: ImageAlignment
    private var scrollResolver = ScrollStepResolver()
    private var earlyClickMonitor: Any?
    private var lastEarlyClickEventNumber: Int?
    #if DEBUG
    var debugBorderColor: NSColor = .cyan
    #endif

    init(plane: SlicePlane, imageAlignment: ImageAlignment, orientation: SliceOrientationLabels) {
        self.plane = plane
        self.imageAlignment = imageAlignment
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let earlyClickMonitor {
            NSEvent.removeMonitor(earlyClickMonitor)
            self.earlyClickMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        earlyClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleEarlyMouseDown(event)
            }
            return event
        }
    }

    private func handleEarlyMouseDown(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else { return }
        lastEarlyClickEventNumber = event.eventNumber
        notifyCursorPosition(at: location)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.mouseDown(with: event)
            return
        }
        // The early local monitor already handled this click immediately on press,
        // bypassing the QuickLook host's gesture-recognizer delay. Skip the duplicate.
        if lastEarlyClickEventNumber == event.eventNumber { return }
        notifyCursorPosition(at: location)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.rightMouseDragged(with: event)
            return
        }
        onWindowAdjust?(event.deltaX, event.deltaY)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.mouseDragged(with: event)
            return
        }
        notifyCursorPosition(at: location)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard imageRect().contains(location) else {
            super.scrollWheel(with: event)
            return
        }
        guard let outcome = scrollResolver.resolve(ScrollStepInput(event), onBegan: { [weak self] in
            self?.onScrollGestureBegan?()
        }) else { return }

        switch outcome.axis {
        case .slice:  onScroll?(plane, outcome.step)
        case .volume: onVolumeScroll?(outcome.step)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let viewport = bounds

        #if DEBUG
        if MIQConfig.debugShowLayoutBorders {
            debugBorderColor.setStroke()
            let debugBorder = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            debugBorder.lineWidth = 2
            debugBorder.stroke()
        }
        #endif

        if let image {
            let imageRect = aspectFitRect(for: image.size, inside: viewport)

            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: imageRect)
            clip.addClip()

            image.draw(
                in: imageRect,
                from: .zero,
                operation: .copy,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )

            NSGraphicsContext.restoreGraphicsState()

            if showAxisLabels {
                drawAxisLabels(for: imageRect, within: viewport)
            }

            if let crosshair {
                drawCrosshair(crosshair, in: imageRect)
            }
        }
    }

    private func aspectFitRect(for size: NSSize, inside rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }

        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale
        let h = size.height * scale

        let x: CGFloat
        switch imageAlignment.horizontal {
        case .leading:
            x = rect.minX
        case .trailing:
            x = rect.maxX - w
        }

        let y: CGFloat
        switch imageAlignment.vertical {
        case .top:
            y = rect.maxY - h
        case .bottom:
            y = rect.minY
        }

        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func drawAxisLabels(for imageRect: NSRect, within boundsRect: NSRect) {
        let cx = imageRect.midX
        let cy = imageRect.midY

        // Unknown-orientation labels render dimmed to signal that the "?" glyphs are
        // a placeholder rather than a confident anatomical claim.
        let effectiveColor = orientation.isUnknown
            ? labelColor.withAlphaComponent(0.35)
            : labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: labelFontSize, weight: .semibold),
            .foregroundColor: effectiveColor
        ]

        let margin: CGFloat = 1

        let leadingSize = (orientation.leading as NSString).size(withAttributes: attrs)
        let trailingSize = (orientation.trailing as NSString).size(withAttributes: attrs)
        let topSize = (orientation.top as NSString).size(withAttributes: attrs)
        let bottomSize = (orientation.bottom as NSString).size(withAttributes: attrs)

        let leadingX = max(boundsRect.minX + 1, imageRect.minX - leadingSize.width - margin)
        let trailingX = min(boundsRect.maxX - trailingSize.width - 1, imageRect.maxX + margin)
        let centerYForLR = max(
            boundsRect.minY + 1,
            min(boundsRect.maxY - leadingSize.height - 1, cy - (leadingSize.height * 0.5))
        )

        let topY = min(boundsRect.maxY - topSize.height - 1, imageRect.maxY + margin)
        let bottomY = max(boundsRect.minY + 1, imageRect.minY - bottomSize.height - margin)

        let topX = max(
            boundsRect.minX + 1,
            min(boundsRect.maxX - topSize.width - 1, cx - (topSize.width * 0.5))
        )
        let bottomX = max(
            boundsRect.minX + 1,
            min(boundsRect.maxX - bottomSize.width - 1, cx - (bottomSize.width * 0.5))
        )

        drawText(orientation.leading, at: NSPoint(x: leadingX, y: centerYForLR), attrs: attrs)
        drawText(orientation.trailing, at: NSPoint(x: trailingX, y: centerYForLR), attrs: attrs)
        drawText(orientation.top, at: NSPoint(x: topX, y: topY), attrs: attrs)
        drawText(orientation.bottom, at: NSPoint(x: bottomX, y: bottomY), attrs: attrs)
    }

    private func drawText(_ text: String, at point: NSPoint, attrs: [NSAttributedString.Key: Any]) {
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private func imageRect() -> NSRect {
        guard let image else { return .zero }
        return aspectFitRect(for: image.size, inside: bounds)
    }

    /// Right edge of the rendered image in this canvas's own coordinates, or
    /// `nil` when nothing is drawn yet. The panel runs to the window edge but
    /// the image is alignment-positioned within it; the metadata scrubber uses
    /// this to stop at the image edge instead of the panel edge.
    var renderedImageRightEdge: CGFloat? {
        image == nil ? nil : imageRect().maxX
    }

    private func notifyCursorPosition(at location: NSPoint) {
        let imageRect = imageRect()
        guard imageRect.width > 0, imageRect.height > 0 else { return }

        let normalizedX = max(0, min(1, Double((location.x - imageRect.minX) / imageRect.width)))
        let normalizedY = max(0, min(1, Double((imageRect.maxY - location.y) / imageRect.height)))
        onCursorPosition?(plane, MIQNormalizedPoint(x: normalizedX, y: normalizedY))
    }

    private func drawCrosshair(_ crosshair: MIQNormalizedPoint, in imageRect: NSRect) {
        let x = imageRect.minX + (CGFloat(crosshair.x) * imageRect.width)
        let y = imageRect.maxY - (CGFloat(crosshair.y) * imageRect.height)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: imageRect.minY))
        path.line(to: NSPoint(x: x, y: imageRect.maxY))
        path.move(to: NSPoint(x: imageRect.minX, y: y))
        path.line(to: NSPoint(x: imageRect.maxX, y: y))
        path.lineWidth = 1.5
        path.setLineDash([5, 5], count: 2, phase: 0)

        labelColor.setStroke()
        path.stroke()
    }
}
