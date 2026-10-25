import Foundation
import MIQCore

/// The update reminder's text in the metadata panel (see `UpdateReminder`).
/// Reads only what the app writes to the App Group, so it costs a few
/// defaults reads per metadata rebuild and never touches the network.
@MainActor
enum UpdateReminderLine {
    /// When this copy of MIQ was installed, approximately: the executable's
    /// modification date, which a release keeps through the zip, Sparkle and
    /// Homebrew.
    private static let installed: Date? = Bundle.main.executableURL.flatMap {
        try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The reminder, two sentences on two lines, or `nil` when none is due or
    /// the reminder is off.
    static var text: String? {
        guard MIQConfig.showsUpdateReminder,
              let days = UpdateReminder.overdueDays(lastCheck: MIQConfig.lastUpdateCheck, installed: installed)
        else { return nil }
        // A line separator, not "\n": one paragraph, so the gap above it isn't
        // repeated between the two lines.
        return "No update check in \(days) days.\u{2028}Open the MIQ app to check."
    }
}
