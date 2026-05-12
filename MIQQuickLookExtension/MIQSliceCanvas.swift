import AppKit
import MIQCore

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

    private let imageAlignment: ImageAlignment
    #if DEBUG
    var debugBorderColor: NSColor = .cyan
    #endif

    init(imageAlignment: ImageAlignment, orientation: SliceOrientationLabels) {
        self.imageAlignment = imageAlignment
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let viewport = bounds

        #if DEBUG
        debugBorderColor.setStroke()
        let debugBorder = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        debugBorder.lineWidth = 2
        debugBorder.stroke()
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

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: labelFontSize, weight: .semibold),
            .foregroundColor: labelColor
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
}
