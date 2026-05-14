import AppKit
import MIQCore

/// Cached bundle of everything the preview UI needs for one (file, settings)
/// combination. Caching at this granularity lets `load()` skip parsing,
/// decompression, slicing, and windowing entirely on a hit.
final class MIQPreviewBundle: NSObject {
    let slices: [SlicePlane: NSImage]
    let orientations: [SlicePlane: SliceOrientationLabels]
    let metadataEntries: [MetadataEntry]

    init(slices: [SlicePlane: NSImage],
         orientations: [SlicePlane: SliceOrientationLabels],
         metadataEntries: [MetadataEntry]) {
        self.slices = slices
        self.orientations = orientations
        self.metadataEntries = metadataEntries
    }
}

enum MIQPreviewCache {
    private nonisolated(unsafe) static let cache = NSCache<NSString, MIQPreviewBundle>()

    static func bundle(for key: String) -> MIQPreviewBundle? {
        return cache.object(forKey: key as NSString)
    }

    static func insert(_ bundle: MIQPreviewBundle, for key: String) {
        cache.setObject(bundle, forKey: key as NSString)
    }

    /// Key derivable without parsing. File path + mtime uniquely identifies
    /// the file's contents; any setting that changes pixel output must be
    /// included here (see CLAUDE.md).
    static func makeKey(
        fileURL: URL,
        maxDimension: Int,
        options: RenderingOptions
    ) -> String {
        let path = fileURL.standardizedFileURL.path
        let modDate: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            modDate = String(format: "%.6f", date.timeIntervalSinceReferenceDate)
        } else {
            modDate = ""
        }
        return "\(path)|\(modDate)|\(maxDimension)|\(options.lowerPercentile)|\(options.upperPercentile)|\(options.orientation.rawValue)"
    }
}
