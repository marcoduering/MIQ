import Foundation

/// Formats the modification date of an executable for the Debug-only "built at"
/// labels shown in the Settings UI and the preview metadata panel.
public enum BuildDate {
    public static func formatted(for executableURL: URL?) -> String? {
        guard let url = executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
