import Foundation
import Testing
@testable import MIQCore

/// The Orientation row names the qform only when its axes disagree with the sform's.
struct QformConflictTests {
    /// Orientation row for a NIfTI with the given sform x-row and an identity
    /// (RAS) qform.
    private func orientationRow(srowX: [Float], srowY: [Float] = [0, 1, 0, 0], qformCode: Int16 = 1) throws -> String? {
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 6, height: 4, depth: 3, datatype: .uint8,
            sformCode: 1,
            srowX: srowX, srowY: srowY, srowZ: [0, 0, 1, 0],
            qformCode: qformCode,
            quaternB: 0, quaternC: 0, quaternD: 0, qfac: 1
        )
        let volume = MIQVolume(image: try MIQParser().parseNifti(data))
        return MIQMetadata(header: volume.image.header, orientation: volume.storageOrientationLabel())
            .asDisplayLines().first { $0.field == .orientation }?.value
    }

    @Test
    func disagreeingAxesNameTheQform() throws {
        #expect(try orientationRow(srowX: [-1, 0, 0, 0]) == "LAS (qform: RAS)")
    }

    @Test
    func roundingDifferencesAreIgnored() throws {
        #expect(try orientationRow(srowX: [0.9999, 0.0001, 0, 0], srowY: [-0.0001, 1.0001, 0, 0]) == "RAS")
    }

    @Test
    func agreeingOrMissingQformShowsOnlyTheCode() throws {
        #expect(try orientationRow(srowX: [1, 0, 0, 0]) == "RAS")
        #expect(try orientationRow(srowX: [-1, 0, 0, 0], qformCode: 0) == "LAS")
    }
}
