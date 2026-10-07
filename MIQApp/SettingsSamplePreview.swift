import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MIQCore

/// The samples bundled for the Settings window's live previews: single-slice
/// NIfTI extracts made with scripts/dev/make_settings_sample.py, stored with
/// reversed rows so "As Stored" visibly differs from the reoriented views, each
/// with a `.window.json` table of the full volume's intensity windows.
/// They are rendered through MIQCore — the same code path as the Quick Look
/// preview and the Finder thumbnail — so what Settings shows is what the
/// extensions will render with the same options.
enum SettingsSample: String, Sendable, CaseIterable {
    case intensity = "SampleIntensity"
    case labels = "SampleLabels"

    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "nii.gz") }
    var windowTableURL: URL? { Bundle.main.url(forResource: rawValue, withExtension: "window.json") }

    /// File name shown under the sample, as if it were a file in Finder.
    var displayName: String {
        switch self {
        case .intensity: return "T1w.nii.gz"
        case .labels:    return "aseg.mgz"
        }
    }
}

/// One rendered axial centre slice plus the edge labels for its orientation.
struct SampleRender: Sendable {
    let bitmap: RGBABitmap
    let labels: SliceOrientationLabels
}

/// Parses each sample once and renders slices off the MainActor.
enum SampleRenderer {
    private static let cache = VolumeCache()

    /// The Quick Look cold path's result for the axial plane. Quick Look takes
    /// the window from all three centre planes of the full volume, which a
    /// single-slice sample doesn't have — so the bounds come from the sample's
    /// window table, computed on the full volume when the sample was made.
    /// Without a table, the window falls back to the slice's own percentiles.
    static func previewSlice(_ sample: SettingsSample, options: RenderingOptions) async -> SampleRender? {
        await Task.detached(priority: .userInitiated) {
            guard let volume = cache.volume(for: sample) else { return nil }
            let lut = volume.buildSegmentationLut(options: options)
            let bounds = lut == nil ? cache.windowTable(for: sample)?.bounds(for: options) : nil
            let slice = volume.centerSlice(plane: .axial, maxDimension: 300, options: options,
                                           windowBounds: bounds, lut: lut)
            guard let bitmap = slice.rgbaBitmap() else { return nil }
            return SampleRender(bitmap: bitmap, labels: volume.displayOrientation(for: .axial, options: options))
        }.value
    }

    /// Matches `MIQThumbnailProvider`: one axial centre slice with an
    /// explicitly built segmentation LUT, windowed from that slice alone — so
    /// the single-slice sample is exact here and needs no window table.
    static func thumbnail(_ sample: SettingsSample, options: RenderingOptions) async -> SampleRender? {
        await Task.detached(priority: .userInitiated) {
            guard let volume = cache.volume(for: sample) else { return nil }
            let lut = volume.buildSegmentationLut(options: options)
            let slice = volume.centerSlice(plane: .axial, maxDimension: 160, options: options, windowBounds: nil, lut: lut)
            guard let bitmap = slice.rgbaBitmap() else { return nil }
            return SampleRender(bitmap: bitmap, labels: volume.displayOrientation(for: .axial, options: options))
        }.value
    }

    /// What the metadata panel would show for a sample: its header rows in the
    /// panel's own vocabulary, plus the voxel value under a centred crosshair.
    struct SampleMetadata: Sendable {
        let entries: [MetadataEntry]
        let centreValue: String
    }

    static func metadata(_ sample: SettingsSample) async -> SampleMetadata? {
        await Task.detached(priority: .userInitiated) {
            guard let volume = cache.volume(for: sample) else { return nil }
            let header = volume.image.header
            var entries = MIQMetadata(header: header, orientation: volume.storageOrientationLabel()).asDisplayLines()
            // Same fallback chain as MIQPreviewModel's Format row.
            let format = header.formatLabel ?? sample.url.flatMap(MIQFileKind.init(url:))?.displayName ?? "Unknown"
            entries.insert(MetadataEntry(field: .format, label: "Format", value: format), at: 0)
            let value = volume.voxel(x: volume.width / 2, y: volume.height / 2, z: volume.depth / 2)
            return SampleMetadata(entries: entries, centreValue: MetadataPanelText.formatVoxelValue(value))
        }.value
    }

    /// Written by scripts/dev/settings_sample_window.swift (same shape).
    struct WindowTable: Decodable {
        let modes: [String: Bounds]

        struct Bounds: Decodable {
            let lower: [Float]
            let upper: [Float]
        }

        /// Settings hold whole percentiles: lower 0…49, upper 51…100.
        func bounds(for options: RenderingOptions) -> MIQIntensityWindowBounds? {
            guard let mode = modes[options.orientation.rawValue] else { return nil }
            let lower = Int(options.lowerPercentile.rounded())
            let upper = Int(options.upperPercentile.rounded()) - 51
            guard mode.lower.indices.contains(lower), mode.upper.indices.contains(upper) else { return nil }
            return MIQIntensityWindowBounds(low: mode.lower[lower], high: mode.upper[upper])
        }
    }

    private final class VolumeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var volumes: [SettingsSample: MIQVolume] = [:]
        private var tables: [SettingsSample: WindowTable] = [:]

        func windowTable(for sample: SettingsSample) -> WindowTable? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = tables[sample] { return cached }
            guard let url = sample.windowTableURL,
                  let data = try? Data(contentsOf: url),
                  let table = try? JSONDecoder().decode(WindowTable.self, from: data) else { return nil }
            tables[sample] = table
            return table
        }

        func volume(for sample: SettingsSample) -> MIQVolume? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = volumes[sample] { return cached }
            guard let url = sample.url,
                  let image = try? MIQParser().parse(url: url) else { return nil }
            let volume = MIQVolume(image: image)
            volumes[sample] = volume
            return volume
        }
    }
}

/// A sample's axial slice on black, with the preview's overlays (axis labels
/// and crosshair) drawn on top the way `MIQSliceCanvas` draws them.
struct SampleSliceView: View {
    let sample: SettingsSample
    let options: RenderingOptions
    var overlayColor: Color
    var showsLabels: Bool
    var showsCrosshair: Bool
    var side: CGFloat = 150

    @State private var render: SampleRender?
    @State private var image: NSImage?

    /// Crosshair position as a fraction of the tile.
    private static let crosshair = CGPoint(x: 0.56, y: 0.45)

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            }
            if showsCrosshair {
                // Off-centre, so the lines don't run through the edge labels
                // (which sit at the middle of each edge).
                Path { path in
                    path.move(to: CGPoint(x: side * Self.crosshair.x, y: 0))
                    path.addLine(to: CGPoint(x: side * Self.crosshair.x, y: side))
                    path.move(to: CGPoint(x: 0, y: side * Self.crosshair.y))
                    path.addLine(to: CGPoint(x: side, y: side * Self.crosshair.y))
                }
                // Same stroke as `MIQSliceCanvas.drawCrosshair`.
                .stroke(overlayColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            }
            if showsLabels, let labels = render?.labels {
                edgeLabels(labels)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement()
        .accessibilityLabel("Sample slice of \(sample.displayName)")
        .task(id: options) {
            guard let result = await SampleRenderer.previewSlice(sample, options: options) else { return }
            render = result
            image = MIQImageBridge.makeNSImage(from: result.bitmap)
        }
    }

    private func edgeLabels(_ labels: SliceOrientationLabels) -> some View {
        ZStack {
            Text(labels.leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Text(labels.trailing).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            Text(labels.top).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Text(labels.bottom).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(overlayColor)
        .shadow(color: .black.opacity(0.8), radius: 1)
        .padding(3)
        .opacity(labels.isUnknown ? 0.5 : 1)
    }
}

/// A sample file as Finder would show it: the slice thumbnail when thumbnails
/// are on, the system's document icon when they are off. Both states share one
/// fixed slot so toggling never shifts the layout.
struct SampleFinderIcon: View {
    let sample: SettingsSample
    let options: RenderingOptions
    let showsThumbnail: Bool

    @State private var image: NSImage?

    private var documentIcon: NSImage {
        let ext = (sample.displayName as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if showsThumbnail {
                    ZStack {
                        Color.black
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(width: 96, height: 96)
                    .overlay(Rectangle().stroke(.black.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                } else {
                    Image(nsImage: documentIcon)
                        .resizable()
                        .frame(width: 96, height: 96)
                }
            }
            .frame(width: 104, height: 104)
            Text(sample.displayName)
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
        .task(id: options) {
            guard let result = await SampleRenderer.thumbnail(sample, options: options) else { return }
            image = MIQImageBridge.makeNSImage(from: result.bitmap)
        }
    }
}

/// The preview's metadata panel text (`MetadataPanelText`), drawn the way the
/// preview's `MetadataView` draws it: TextKit, black panel, uniform inset.
struct MetadataPanelSample: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context _: Context) -> PanelTextView { PanelTextView() }

    func updateNSView(_ view: PanelTextView, context _: Context) {
        view.text = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PanelTextView, context _: Context) -> CGSize? {
        let width = proposal.width ?? 180
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    final class PanelTextView: NSView {
        static let inset: CGFloat = 12
        private let textStorage = NSTextStorage()
        private let layoutManager = NSLayoutManager()
        private let textContainer = NSTextContainer()

        var text = NSAttributedString() {
            didSet {
                textStorage.setAttributedString(text)
                needsDisplay = true
            }
        }

        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            textContainer.lineFragmentPadding = 0
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func height(forWidth width: CGFloat) -> CGFloat {
            layOut(width: width)
            return ceil(layoutManager.usedRect(for: textContainer).height) + 2 * Self.inset
        }

        override func draw(_: NSRect) {
            NSColor.black.setFill()
            bounds.fill()
            layOut(width: bounds.width)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: Self.inset, y: Self.inset))
        }

        private func layOut(width: CGFloat) {
            textContainer.size = CGSize(width: max(0, width - 2 * Self.inset), height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
        }
    }
}
