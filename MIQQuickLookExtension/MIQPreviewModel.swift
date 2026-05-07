import AppKit
import Foundation
import OSLog
import MIQCore

@MainActor
final class MIQPreviewModel {
    private let logger = MIQLogger.make(category: "model")

    private struct PreviewData {
        let slices: [SlicePlane: SliceImage]
        let orientations: [SlicePlane: SliceOrientationLabels]
        let metadataLines: [String]
        let cacheKey: String
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
    var metadataLines: [String] = []

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() async {
        state = .loading
        let fileURL = self.url
        let typeLine = Self.metadataTypeLine(for: fileURL)
        logger.notice("load() started for: \(fileURL.lastPathComponent, privacy: .public)")
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> PreviewData in
                let image = try MIQParser().parse(url: fileURL)
                let volume = MIQVolume(image: image)
                let dimensions = "\(image.header.width)x\(image.header.height)x\(image.header.depth)x\(image.header.volumes)"
                let cacheKey = MIQSliceCache.makeKey(
                    fileURL: fileURL,
                    dimensions: dimensions,
                    datatype: image.header.datatype.label,
                    maxDimension: 512
                )

                var slices: [SlicePlane: SliceImage] = [:]
                var orientations: [SlicePlane: SliceOrientationLabels] = [:]
                for plane in SlicePlane.allCases {
                    slices[plane] = volume.centerSlice(plane: plane, volumeIndex: 0, maxDimension: 512)
                    orientations[plane] = volume.displayOrientation(for: plane)
                }

                var metadata = MIQMetadata(header: image.header, orientation: volume.storageOrientationLabel()).asDisplayLines()
                metadata.insert(typeLine, at: 0)
                #if DEBUG
                if let built = Self.buildDateLine() { metadata.append(built) }
                #endif

                return PreviewData(
                    slices: slices,
                    orientations: orientations,
                    metadataLines: metadata,
                    cacheKey: cacheKey
                )
            }.value

            var images: [SlicePlane: NSImage] = [:]
            for plane in SlicePlane.allCases {
                let key = MIQSliceCache.sliceKey(baseKey: result.cacheKey, plane: plane)
                if let cached = MIQSliceCache.image(for: key) {
                    images[plane] = cached
                } else if let slice = result.slices[plane], let made = MIQImageBridge.makeNSImage(from: slice) {
                    images[plane] = made
                    MIQSliceCache.insert(made, for: key)
                }
            }

            coronal = images[.coronal]
            sagittal = images[.sagittal]
            axial = images[.axial]
            coronalOrientation = result.orientations[.coronal] ?? .placeholderCoronal
            sagittalOrientation = result.orientations[.sagittal] ?? .placeholderSagittal
            axialOrientation = result.orientations[.axial] ?? .placeholderAxial
            metadataLines = result.metadataLines
            state = .ready
            logger.notice("load() finished successfully")
        } catch {
            logger.error("load() failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func metadataTypeLine(for url: URL) -> String {
        let displayName = MIQFileKind(url: url)?.displayName ?? "Unknown"
        return "Type: \(displayName)"
    }

    #if DEBUG
    private nonisolated static func buildDateLine() -> String? {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "Built: \(fmt.string(from: date))"
    }
    #endif
}
