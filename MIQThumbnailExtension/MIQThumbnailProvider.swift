import AppKit
import OSLog
import QuickLookThumbnailing
import MIQCore

/// Quick Look thumbnail provider. Renders the axial centre slice of volume 0
/// as a static image — no labels, crosshair, interaction, or 4D navigation.
///
/// Claims the broad gzip UTIs (`public.gzip` / `org.gnu.gnu-zip-archive`)
/// because macOS resolves `.nii.gz` to `org.gnu.gnu-zip-archive`, not to the
/// narrow `org.nifti.nii-gz` UTI. Unrelated `.gz` archives are declined via
/// `MIQFileKind` so they keep the system archive icon.
final class MIQThumbnailProvider: QLThumbnailProvider {
    private let logger = MIQLogger.make(category: "thumbnail")

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL

        guard MIQConfig.showThumbnails else {
            handler(nil, nil)
            return
        }

        guard MIQFileKind(url: url) != nil else {
            logger.notice("declining non-volume file, deferring to system icon: \(url.lastPathComponent, privacy: .public)")
            handler(nil, nil)
            return
        }

        do {
            let image = try Self.renderAxialCenter(url: url, request: request)
            let contextSize = Self.aspectFit(imageSize: image.size, within: request.maximumSize)
            let reply = QLThumbnailReply(contextSize: contextSize, currentContextDrawing: {
                image.draw(in: NSRect(origin: .zero, size: contextSize))
                return true
            })
            logger.notice("thumbnail rendered for: \(url.lastPathComponent, privacy: .public)")
            handler(reply, nil)
        } catch {
            logger.error("thumbnail failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            handler(nil, error)
        }
    }

    // MARK: - Rendering

    private static func renderAxialCenter(url: URL, request: QLFileThumbnailRequest) throws -> NSImage {
        try withSecurityScopedAccess(to: url) {
            let image = try MIQParser().parse(url: url)
            let volume = MIQVolume(image: image)

            let options = RenderingOptions(
                lowerPercentile: MIQConfig.thumbnailWindowLowerPercentile,
                upperPercentile: MIQConfig.thumbnailWindowUpperPercentile,
                orientation: MIQConfig.thumbnailImageOrientation
            )

            let slice = volume.centerSlice(
                plane: .axial,
                volumeIndex: 0,
                maxDimension: thumbnailPixelBudget(for: request),
                options: options
            )

            guard let nsImage = MIQImageBridge.makeNSImage(from: slice) else {
                throw MIQError.malformedFile("thumbnail: could not build an image from the axial centre slice")
            }
            return nsImage
        }
    }

    /// Pixel cap for the rendered slice, derived from the requested size × scale
    /// and clamped so an unusually large request can't blow the render budget.
    private static func thumbnailPixelBudget(for request: QLFileThumbnailRequest) -> Int {
        let longestPoints = max(request.maximumSize.width, request.maximumSize.height)
        let pixels = Int((longestPoints * request.scale).rounded())
        // Cap at 512: medical volumes are rarely >256² per slice, so a larger
        // render budget only upscales (nearest-neighbor) without adding detail.
        return min(512, max(64, pixels))
    }

    private static func aspectFit(imageSize: CGSize, within maxSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              maxSize.width > 0, maxSize.height > 0 else { return maxSize }
        let scale = min(maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        return CGSize(width: max(1, imageSize.width * scale), height: max(1, imageSize.height * scale))
    }

    private static func withSecurityScopedAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
