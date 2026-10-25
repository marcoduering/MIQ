import Foundation
import Testing
@testable import MIQCore

/// `UpdateReminder.overdueDays` decides when the preview's update reminder
/// shows.
struct UpdateReminderTests {
    private static let day = UpdateReminder.secondsPerDay
    private static let now = Date()

    @Test func remindsOnlyAfterTheInterval() {
        let justBefore = Self.now.addingTimeInterval(-Double(UpdateReminder.intervalDays) * Self.day + 60)
        #expect(UpdateReminder.overdueDays(lastCheck: justBefore, installed: nil, now: Self.now) == nil)
        let fortyDays = Self.now.addingTimeInterval(-40 * Self.day)
        #expect(UpdateReminder.overdueDays(lastCheck: fortyDays, installed: nil, now: Self.now) == 40)
    }

    @Test func lastCheckWinsOverInstallDate() {
        let recent = Self.now.addingTimeInterval(-2 * Self.day)
        let old = Self.now.addingTimeInterval(-100 * Self.day)
        #expect(UpdateReminder.overdueDays(lastCheck: recent, installed: old, now: Self.now) == nil)
    }

    @Test func installDateStandsInForMissingCheck() {
        let recent = Self.now.addingTimeInterval(-2 * Self.day)
        #expect(UpdateReminder.overdueDays(lastCheck: nil, installed: recent, now: Self.now) == nil)
        let old = Self.now.addingTimeInterval(-60 * Self.day)
        #expect(UpdateReminder.overdueDays(lastCheck: nil, installed: old, now: Self.now) == 60)
    }

    @Test func noDateNoReminder() {
        #expect(UpdateReminder.overdueDays(lastCheck: nil, installed: nil, now: Self.now) == nil)
    }

    @Test func futureDateNoReminder() {
        // A clock set back: the next real check fixes it; until then, stay quiet.
        let future = Self.now.addingTimeInterval(3 * Self.day)
        #expect(UpdateReminder.overdueDays(lastCheck: future, installed: nil, now: Self.now) == nil)
    }
}
