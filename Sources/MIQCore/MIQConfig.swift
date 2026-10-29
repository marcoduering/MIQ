import Foundation
import os.log

public enum MIQConfig {
    private static let configLogger = Logger(subsystem: "miq.core", category: "config")
    nonisolated(unsafe) private static var loggedMissingAppGroupID = false

    public static var appGroupID: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "MIQAppGroupID") as? String, !value.isEmpty {
            return value
        }
        if !loggedMissingAppGroupID {
            loggedMissingAppGroupID = true
            configLogger.notice("MIQAppGroupID missing from Info.plist — falling back to UserDefaults.standard; settings won't propagate between app and extension")
        }
        return ""
    }

    public enum Keys {
        public static let showAxisLabels        = "showAxisLabels"
        public static let windowLowerPercentile = "windowLowerPercentile"
        public static let windowUpperPercentile = "windowUpperPercentile"
        public static let perVolumeIntensityWindow = "perVolumeIntensityWindow"
        public static let imageOrientation      = "imageOrientation"
        public static let axisLabelColor        = "axisLabelColor"
        public static let showMetadataFormat      = "showMetadataFormat"
        public static let showMetadataDimensions  = "showMetadataDimensions"
        public static let showMetadataSpacing     = "showMetadataSpacing"
        public static let showMetadataOrientation = "showMetadataOrientation"
        public static let showMetadataDatatype    = "showMetadataDatatype"
        public static let showMetadataVolumes     = "showMetadataVolumes"
        public static let showMetadataScaling     = "showMetadataScaling"
        public static let showMetadataValue       = "showMetadataValue"
        public static let showMetadataComment     = "showMetadataComment"
        public static let metadataOrder           = "metadataOrder"
        public static let segmentationColoring           = "segmentationColoring"
        public static let hideDisclaimerInPreview = "hideDisclaimerInPreview"
        /// Legacy on/off switch for the network deferral, superseded by
        /// `networkPreviewThresholdMB`; read only to carry an "off" forward.
        public static let deferLargeNetworkPreviews = "deferLargeNetworkPreviews"
        public static let networkPreviewThresholdMB = "networkPreviewThresholdMB"
        public static let starBannerDismissed     = "starBannerDismissed"
        public static let showThumbnails                 = "showThumbnails"
        public static let showThumbnailsOnNetworkVolumes = "showThumbnailsOnNetworkVolumes"
        public static let thumbnailImageOrientation      = "thumbnailImageOrientation"
        public static let thumbnailSegmentationColoring  = "thumbnailSegmentationColoring"
        public static let thumbnailWindowLowerPercentile = "thumbnailWindowLowerPercentile"
        public static let thumbnailWindowUpperPercentile = "thumbnailWindowUpperPercentile"
        public static let thumbnailSizeLimitMB           = "thumbnailSizeLimitMB"
        public static let updateReminderInPreview = "updateReminderInPreview"
        public static let automaticUpdateChecks   = "automaticUpdateChecks"
        public static let lastUpdateCheck         = "lastUpdateCheck"
        #if DEBUG
        public static let debugShowLayoutBorders  = "debugShowLayoutBorders"
        #endif
    }

    public enum Defaults {
        public static let showAxisLabels        = true
        public static let windowLowerPercentile = 2.0
        public static let windowUpperPercentile = 98.0
        public static let perVolumeIntensityWindow = true
        public static let imageOrientation      = "stored"
        public static let axisLabelColor        = "1.0,0.15,0.1,1.0"
        public static let showMetadataFormat      = true
        public static let showMetadataDimensions  = true
        public static let showMetadataSpacing     = true
        public static let showMetadataOrientation = true
        public static let showMetadataDatatype    = true
        public static let showMetadataVolumes     = true
        public static let showMetadataScaling     = true
        public static let showMetadataValue       = true
        public static let showMetadataComment     = false
        public static let metadataOrder           = "format,dimensions,spacing,orientation,datatype,volumes,scaling,value,comment"
        public static let segmentationColoring           = "auto"
        public static let hideDisclaimerInPreview = false
        /// App-only (the Settings window's "star on GitHub" banner); the
        /// extensions never read it.
        public static let starBannerDismissed     = false
        /// Size (MB) above which the preview defers a non-boundable file on a
        /// network volume behind a "Load Preview" button. 0 means never defer.
        public static let networkPreviewThresholdMB = 100.0
        public static let showThumbnails                 = false
        public static let showThumbnailsOnNetworkVolumes = false
        public static let thumbnailImageOrientation      = "stored"
        public static let thumbnailSegmentationColoring  = "auto"
        public static let thumbnailWindowLowerPercentile = 2.0
        public static let thumbnailWindowUpperPercentile = 98.0
        /// Size (MB) above which the thumbnail extension declines files it would
        /// have to read or decompress in full (`MIQFileKind.declinesThumbnail`).
        /// 0 means no limit.
        public static let thumbnailSizeLimitMB           = 100.0
        public static let updateReminderInPreview = true
        /// Must match `SUEnableAutomaticChecks` in MIQApp/Info.plist: it stands in
        /// for Sparkle's setting until the app first runs and mirrors it.
        public static let automaticUpdateChecks   = true
    }

    public struct MIQColor: Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double
    }

    /// Shared App Group store, resolved once. Cached rather than reconstructed
    /// per access because the extension reads ~10 settings per rendered frame
    /// during interaction (axis labels, overlay colour, metadata order/visibility),
    /// and `UserDefaults(suiteName:)` allocates on every call. The getters still
    /// read values live via `object(forKey:)`, so app-side writes remain visible.
    /// `nonisolated(unsafe)` mirrors `MIQPreviewCache.cache`: `UserDefaults` is
    /// thread-safe by Apple's contract, so concurrent reads are sound.
    ///
    /// The empty-`appGroupID` check is load-bearing, not defensive noise:
    /// `UserDefaults(suiteName: "")` returns a **non-nil** store (a nameless
    /// suite), so a bare `?? .standard` never fires and the app and each appex
    /// would silently read three different stores — while `appGroupID` logs that
    /// it fell back to `.standard`. Reachable whenever `MIQAppGroupID` resolves
    /// empty, i.e. `APP_GROUP_ID` is undefined because `LocalSigning.xcconfig`
    /// (gitignored) is missing from a fresh checkout.
    nonisolated(unsafe) private static let defaults: UserDefaults = {
        let identifier = appGroupID
        guard !identifier.isEmpty, let suite = UserDefaults(suiteName: identifier) else {
            return .standard
        }
        return suite
    }()

    public static var showAxisLabels: Bool {
        let d = defaults
        return d.object(forKey: Keys.showAxisLabels) as? Bool ?? Defaults.showAxisLabels
    }

    public static var windowLowerPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.windowLowerPercentile) as? Double ?? Defaults.windowLowerPercentile
    }

    public static var windowUpperPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.windowUpperPercentile) as? Double ?? Defaults.windowUpperPercentile
    }

    /// When `true`, 4D previews re-derive the percentile window from each
    /// volume's own pooled center slices instead of reusing volume 0's window
    /// for the whole timeseries. Deliberately *not* part of `RenderingOptions`:
    /// the cache only holds the volume-0 cold preview, whose window is identical
    /// either way, so this never needs to invalidate the cache. It is a
    /// model-layer choice of *which* bounds to feed `MIQVolume.slice`, consumed
    /// only by the extension's interactive render path.
    public static var perVolumeIntensityWindow: Bool {
        let d = defaults
        return d.object(forKey: Keys.perVolumeIntensityWindow) as? Bool ?? Defaults.perVolumeIntensityWindow
    }

    public static var imageOrientation: ViewOrientation {
        let raw = defaults.string(forKey: Keys.imageOrientation) ?? Defaults.imageOrientation
        return ViewOrientation(rawValue: raw) ?? .stored
    }

    public static var axisLabelColor: MIQColor {
        let raw = defaults.string(forKey: Keys.axisLabelColor) ?? Defaults.axisLabelColor
        return parseColor(raw) ?? parseColor(Defaults.axisLabelColor)!
    }

    /// User-configured display order for metadata fields. Unknown tokens are
    /// dropped; any `MetadataField` not present in the stored value is appended
    /// in canonical order so the result always covers every case.
    public static var metadataOrder: [MetadataField] {
        let raw = defaults.string(forKey: Keys.metadataOrder) ?? Defaults.metadataOrder
        return parseMetadataOrder(raw)
    }

    public static func parseMetadataOrder(_ raw: String) -> [MetadataField] {
        var seen = Set<MetadataField>()
        var ordered: [MetadataField] = []
        for token in raw.split(separator: ",") {
            guard let field = MetadataField(rawValue: String(token)), !seen.contains(field) else { continue }
            ordered.append(field)
            seen.insert(field)
        }
        for field in MetadataField.allCases where !seen.contains(field) {
            ordered.append(field)
        }
        return ordered
    }

    public static var segmentationColoring: SegmentationColoring {
        let raw = defaults.string(forKey: Keys.segmentationColoring) ?? Defaults.segmentationColoring
        return SegmentationColoring(rawValue: raw) ?? .auto
    }

    public static var hideDisclaimerInPreview: Bool {
        let d = defaults
        return d.object(forKey: Keys.hideDisclaimerInPreview) as? Bool ?? Defaults.hideDisclaimerInPreview
    }

    /// Byte threshold above which the preview extension defers the heavy
    /// full-file read for non-boundable kinds (`.mgz`/`.mif.gz`/`.nrrd`/`.mha`, and
    /// `.mgh`/`.mif`) on a network volume, showing a "Load Preview" placeholder
    /// instead of auto-pulling it. Prevents a large read from stalling Finder's
    /// own I/O on a slow mount. Local disk and canonical NIfTI (already bounded
    /// to volume 0) are unaffected. `nil` means never defer. Read by the preview
    /// extension only.
    public static var networkPreviewThresholdBytes: Int? {
        let mb = networkPreviewThresholdMB
        return mb > 0 ? Int(mb * 1024 * 1024) : nil
    }

    /// The stored threshold in MB (0 = never defer). Until the setting is first
    /// written, a legacy `deferLargeNetworkPreviews = false` reads as 0, so a
    /// user who switched the old toggle off keeps never being asked.
    public static var networkPreviewThresholdMB: Double {
        let d = defaults
        if let mb = d.object(forKey: Keys.networkPreviewThresholdMB) as? Double { return mb }
        if d.object(forKey: Keys.deferLargeNetworkPreviews) as? Bool == false { return 0 }
        return Defaults.networkPreviewThresholdMB
    }

    /// Writes the legacy toggle's value into `networkPreviewThresholdMB` once, so
    /// the app's picker (bound to the new key) shows it. Called at app launch.
    public static func migrateLegacyNetworkPreviewSetting() {
        let d = defaults
        guard d.object(forKey: Keys.deferLargeNetworkPreviews) != nil else { return }
        if d.object(forKey: Keys.networkPreviewThresholdMB) == nil {
            d.set(networkPreviewThresholdMB, forKey: Keys.networkPreviewThresholdMB)
        }
        d.removeObject(forKey: Keys.deferLargeNetworkPreviews)
    }

    // MARK: - Thumbnails (Finder / Quick Look thumbnail extension)
    // Independent of the Preview pane's settings: a user can want, e.g.,
    // stored-orientation previews but radiological thumbnails. Read by the
    // thumbnail extension only.

    public static var showThumbnails: Bool {
        let d = defaults
        return d.object(forKey: Keys.showThumbnails) as? Bool ?? Defaults.showThumbnails
    }

    /// When `false` (default), the thumbnail extension declines files on network
    /// volumes, so browsing a remote share doesn't spawn a parse per file. Local
    /// thumbnails are unaffected. Read by the thumbnail extension only.
    public static var showThumbnailsOnNetworkVolumes: Bool {
        let d = defaults
        return d.object(forKey: Keys.showThumbnailsOnNetworkVolumes) as? Bool ?? Defaults.showThumbnailsOnNetworkVolumes
    }

    public static var thumbnailImageOrientation: ViewOrientation {
        let raw = defaults.string(forKey: Keys.thumbnailImageOrientation) ?? Defaults.thumbnailImageOrientation
        return ViewOrientation(rawValue: raw) ?? .stored
    }

    public static var thumbnailSegmentationColoring: SegmentationColoring {
        let raw = defaults.string(forKey: Keys.thumbnailSegmentationColoring) ?? Defaults.thumbnailSegmentationColoring
        return SegmentationColoring(rawValue: raw) ?? .auto
    }

    public static var thumbnailWindowLowerPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.thumbnailWindowLowerPercentile) as? Double ?? Defaults.thumbnailWindowLowerPercentile
    }

    public static var thumbnailWindowUpperPercentile: Double {
        let d = defaults
        return d.object(forKey: Keys.thumbnailWindowUpperPercentile) as? Double ?? Defaults.thumbnailWindowUpperPercentile
    }

    /// Byte form of `thumbnailSizeLimitMB`, ready for
    /// `MIQFileKind.declinesThumbnail`. A limit of 0 (or less) means no limit.
    public static var thumbnailSizeLimitBytes: Int {
        let mb = defaults.object(forKey: Keys.thumbnailSizeLimitMB) as? Double ?? Defaults.thumbnailSizeLimitMB
        return mb > 0 ? Int(mb * 1024 * 1024) : .max
    }

    // MARK: - Update reminder (preview extension; see `UpdateReminder`)

    /// Whether the preview shows the update reminder: the user's own setting,
    /// and only while the app's automatic update checks are on.
    public static var showsUpdateReminder: Bool {
        let d = defaults
        return automaticUpdateChecks
            && (d.object(forKey: Keys.updateReminderInPreview) as? Bool ?? Defaults.updateReminderInPreview)
    }

    /// Mirror of Sparkle's "check automatically" setting, which lives in the
    /// app's own defaults where the extension can't read them. Written by the
    /// app's `UpdaterController` only.
    public static var automaticUpdateChecks: Bool {
        get { defaults.object(forKey: Keys.automaticUpdateChecks) as? Bool ?? Defaults.automaticUpdateChecks }
        set { defaults.set(newValue, forKey: Keys.automaticUpdateChecks) }
    }

    /// Mirror of Sparkle's `lastUpdateCheckDate`. Written by the app's
    /// `UpdaterController` only — Quick Look's sandbox denies the extension
    /// writes to the App Group.
    public static var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheck) }
    }

    #if DEBUG
    public static var debugShowLayoutBorders: Bool {
        defaults.object(forKey: Keys.debugShowLayoutBorders) as? Bool ?? false
    }
    #endif

    public static func showMetadataField(_ field: MetadataField) -> Bool {
        let d = defaults
        let (key, fallback): (String, Bool) = {
            switch field {
            case .format:      return (Keys.showMetadataFormat,      Defaults.showMetadataFormat)
            case .dimensions:  return (Keys.showMetadataDimensions,  Defaults.showMetadataDimensions)
            case .spacing:     return (Keys.showMetadataSpacing,     Defaults.showMetadataSpacing)
            case .orientation: return (Keys.showMetadataOrientation, Defaults.showMetadataOrientation)
            case .datatype:    return (Keys.showMetadataDatatype,    Defaults.showMetadataDatatype)
            case .volumes:     return (Keys.showMetadataVolumes,     Defaults.showMetadataVolumes)
            case .scaling:     return (Keys.showMetadataScaling,     Defaults.showMetadataScaling)
            case .value:       return (Keys.showMetadataValue,       Defaults.showMetadataValue)
            case .comment:     return (Keys.showMetadataComment,     Defaults.showMetadataComment)
            }
        }()
        return d.object(forKey: key) as? Bool ?? fallback
    }

    private static func parseColor(_ str: String) -> MIQColor? {
        let parts = str.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return MIQColor(red: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }
}
