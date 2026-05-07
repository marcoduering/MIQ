import AppKit
import MIQCore

enum MIQSliceCache {
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    static func image(for key: String) -> NSImage? {
        return cache.object(forKey: key as NSString)
    }

    static func insert(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    static func makeKey(
        fileURL: URL,
        dimensions: String,
        datatype: String,
        maxDimension: Int
    ) -> String {
        let path = fileURL.standardizedFileURL.path
        let modDate: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let date = attrs[.modificationDate] as? Date {
            modDate = String(date.timeIntervalSinceReferenceDate)
        } else {
            modDate = ""
        }
        return "\(path)|\(modDate)|\(dimensions)|\(datatype)|\(maxDimension)"
    }

    static func sliceKey(baseKey: String, plane: SlicePlane) -> String {
        return "\(baseKey)|\(plane.rawValue)"
    }
}