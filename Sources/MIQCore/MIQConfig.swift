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
        public static let imageOrientation      = "imageOrientation"
        public static let axisLabelColor        = "axisLabelColor"
        public static let showMetadataFormat      = "showMetadataFormat"
        public static let showMetadataDimensions  = "showMetadataDimensions"
        public static let showMetadataSpacing     = "showMetadataSpacing"
        public static let showMetadataOrientation = "showMetadataOrientation"
        public static let showMetadataDatatype    = "showMetadataDatatype"
        public static let showMetadataVolumes     = "showMetadataVolumes"
        public static let showMetadataScaling     = "showMetadataScaling"
        public static let metadataOrder           = "metadataOrder"
        public static let hideDisclaimerInPreview = "hideDisclaimerInPreview"
    }

    public enum Defaults {
        public static let showAxisLabels        = true
        public static let windowLowerPercentile = 2.0
        public static let windowUpperPercentile = 98.0
        public static let imageOrientation      = "stored"
        public static let axisLabelColor        = "1.0,0.15,0.1,1.0"
        public static let showMetadataFormat      = true
        public static let showMetadataDimensions  = true
        public static let showMetadataSpacing     = true
        public static let showMetadataOrientation = true
        public static let showMetadataDatatype    = true
        public static let showMetadataVolumes     = true
        public static let showMetadataScaling     = true
        public static let metadataOrder           = "format,dimensions,spacing,orientation,datatype,volumes,scaling"
        public static let hideDisclaimerInPreview = false
    }

    public struct MIQColor: Sendable {
        public let red, green, blue, alpha: Double
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

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

    public static var hideDisclaimerInPreview: Bool {
        let d = defaults
        return d.object(forKey: Keys.hideDisclaimerInPreview) as? Bool ?? Defaults.hideDisclaimerInPreview
    }

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
