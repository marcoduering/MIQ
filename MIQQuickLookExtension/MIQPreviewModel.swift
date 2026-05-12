import AppKit
import Foundation
import OSLog
import MIQCore

@MainActor
final class MIQPreviewModel {
    private let logger = MIQLogger.make(category: "model")

    private struct RawPreviewData: Sendable {
        let slices: [SlicePlane: SliceImage]
        let orientations: [SlicePlane: SliceOrientationLabels]
        let metadataEntries: [MetadataEntry]
    }

    enum State {
        case idle
        case loading
        case ready
        case failed(String)
    }

    var state: State = .idle
    var coronal: NSImage?
    var sagittal: NSImage?
    var axial: NSImage?
    var coronalOrientation = SliceOrientationLabels.placeholderCoronal
    var sagittalOrientation = SliceOrientationLabels.placeholderSagittal
    var axialOrientation = SliceOrientationLabels.placeholderAxial
    var metadataEntries: [MetadataEntry] = []

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() async {
        state = .loading
        let fileURL = self.url
        let formatEntry = Self.metadataFormatEntry(for: fileURL)
        let options = RenderingOptions(
            lowerPercentile: MIQConfig.windowLowerPercentile,
            upperPercentile: MIQConfig.windowUpperPercentile,
            orientation: MIQConfig.imageOrientation
        )
        let maxDimension = 512
        let cacheKey = MIQPreviewCache.makeKey(fileURL: fileURL, maxDimension: maxDimension, options: options)
        logger.notice("load() started for: \(fileURL.lastPathComponent, privacy: .public)")
        logger.notice("MIQConfig percentiles: lower=\(options.lowerPercentile, privacy: .public), upper=\(options.upperPercentile, privacy: .public), orientation=\(options.orientation.rawValue, privacy: .public), showAxisLabels=\(MIQConfig.showAxisLabels, privacy: .public)")

        if let cached = MIQPreviewCache.bundle(for: cacheKey) {
            logger.notice("load() cache hit — skipping parse")
            apply(bundle: cached)
            state = .ready
            return
        }

        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            let raw = try await Task.detached(priority: .userInitiated) { () -> RawPreviewData in
                let image = try MIQParser().parse(url: fileURL)
                let volume = MIQVolume(image: image)

                let slices = volume.centerSlices(volumeIndex: 0, maxDimension: maxDimension, options: options)
                var orientations: [SlicePlane: SliceOrientationLabels] = [:]
                for plane in SlicePlane.allCases {
                    orientations[plane] = volume.displayOrientation(for: plane, options: options)
                }

                var metadata = MIQMetadata(header: image.header, orientation: volume.storageOrientationLabel()).asDisplayLines()
                metadata.insert(formatEntry, at: 0)
                #if DEBUG
                if let built = Self.buildDateEntry() { metadata.append(built) }
                #endif

                return RawPreviewData(slices: slices, orientations: orientations, metadataEntries: metadata)
            }.value

            var nsSlices: [SlicePlane: NSImage] = [:]
            for plane in SlicePlane.allCases {
                if let sliceImage = raw.slices[plane], let ns = MIQImageBridge.makeNSImage(from: sliceImage) {
                    nsSlices[plane] = ns
                }
            }
            let bundle = MIQPreviewBundle(
                slices: nsSlices,
                orientations: raw.orientations,
                metadataEntries: raw.metadataEntries
            )
            MIQPreviewCache.insert(bundle, for: cacheKey)
            apply(bundle: bundle)
            state = .ready
            logger.notice("load() finished successfully")
        } catch {
            logger.error("load() failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func apply(bundle: MIQPreviewBundle) {
        coronal = bundle.slices[.coronal]
        sagittal = bundle.slices[.sagittal]
        axial = bundle.slices[.axial]
        coronalOrientation = bundle.orientations[.coronal] ?? .placeholderCoronal
        sagittalOrientation = bundle.orientations[.sagittal] ?? .placeholderSagittal
        axialOrientation = bundle.orientations[.axial] ?? .placeholderAxial
        metadataEntries = bundle.metadataEntries
    }

    private nonisolated static func metadataFormatEntry(for url: URL) -> MetadataEntry {
        let displayName = MIQFileKind(url: url)?.displayName ?? "Unknown"
        return MetadataEntry(field: .format, text: "Format: \(displayName)")
    }

    #if DEBUG
    private nonisolated static func buildDateEntry() -> MetadataEntry? {
        guard let formatted = BuildDate.formatted(for: Bundle.main.executableURL) else { return nil }
        return MetadataEntry(field: nil, text: "Built: \(formatted)")
    }
    #endif
}
