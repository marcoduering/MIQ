import Foundation
import Testing
@testable import MIQCore

struct UpdateCheckerTests {
    @Test func detectsHigherPatch() {
        #expect(UpdateChecker.isNewer(latest: "0.2.1", than: "0.2.0"))
    }

    @Test func detectsHigherMinor() {
        #expect(UpdateChecker.isNewer(latest: "0.3.0", than: "0.2.9"))
    }

    @Test func detectsHigherMajor() {
        #expect(UpdateChecker.isNewer(latest: "1.0.0", than: "0.99.99"))
    }

    @Test func equalVersionsAreNotNewer() {
        #expect(!UpdateChecker.isNewer(latest: "0.2.0", than: "0.2.0"))
    }

    @Test func olderVersionsAreNotNewer() {
        #expect(!UpdateChecker.isNewer(latest: "0.1.9", than: "0.2.0"))
    }

    @Test func tolerantOfLeadingV() {
        #expect(UpdateChecker.isNewer(latest: "v0.3.0", than: "0.2.0"))
        #expect(UpdateChecker.isNewer(latest: "v0.3.0", than: "v0.2.0"))
        #expect(!UpdateChecker.isNewer(latest: "v0.2.0", than: "v0.2.0"))
    }

    @Test func differentLengthsArePaddedWithZero() {
        #expect(!UpdateChecker.isNewer(latest: "0.2", than: "0.2.0"))
        #expect(UpdateChecker.isNewer(latest: "0.2.1", than: "0.2"))
        #expect(!UpdateChecker.isNewer(latest: "0.2", than: "0.2.1"))
    }

    @Test func prereleaseSuffixIsIgnoredForOrdering() {
        // "0.3.0-rc.1" is treated as 0.3.0 for the purpose of strict comparison.
        // This is conservative: we never want to falsely claim an update.
        #expect(!UpdateChecker.isNewer(latest: "0.3.0-rc.1", than: "0.3.0"))
        #expect(UpdateChecker.isNewer(latest: "0.3.0-rc.1", than: "0.2.0"))
    }

    @Test func malformedInputDoesNotAdvertiseUpdate() {
        #expect(!UpdateChecker.isNewer(latest: "", than: "0.2.0"))
        #expect(!UpdateChecker.isNewer(latest: "abc", than: "0.2.0"))
        #expect(!UpdateChecker.isNewer(latest: "0.2.0", than: ""))
    }
}
