import Foundation

/// The preview's update reminder. MIQ.app's Sparkle updater only checks while
/// the app is open, which users rarely do once their settings are made, so the
/// preview reminds them when the app hasn't checked for a while. Opening the
/// app is enough: Sparkle checks at launch once its own one-day interval has
/// passed, and the app then mirrors the new check into
/// `MIQConfig.lastUpdateCheck`, which clears the reminder.
///
/// A reminder the user acts on, rather than a check or a link, because Quick
/// Look's sandbox allows neither (measured Oct 2026): the preview extension is
/// denied network access despite a `network.client` entitlement (the DNS lookup
/// is refused), LaunchServices opens (`lsopen`), and the host answers `false`
/// to `NSExtensionContext.open`.
public enum UpdateReminder {
    /// How many days without an update check before the preview reminds.
    public static let intervalDays = 30

    static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// Whole days since the last update check when a reminder is due, else `nil`.
    ///
    /// - Parameters:
    ///   - lastCheck: the app's last Sparkle check; `nil` if the app has never
    ///     recorded one (not launched since installing this version).
    ///   - installed: stands in for a missing `lastCheck`, so a fresh install
    ///     doesn't remind at once.
    public static func overdueDays(lastCheck: Date?, installed: Date?, now: Date = Date()) -> Int? {
        guard let reference = lastCheck ?? installed else { return nil }
        let days = Int(now.timeIntervalSince(reference) / secondsPerDay)
        return days >= intervalDays ? days : nil
    }
}
