import Foundation
import Testing
@testable import MIQCore

/// The Orientation row names the qform only when its axes disagree with the sform's.
struct QformConflictTests {
    /// Orientation row for a NIfTI with the given sform x/y rows and a qform rotated
    /// by `quaternD` about z (0 = identity, RAS).
    private func orientationRow(
        srowX: [Float],
        srowY: [Float] = [0, 1, 0, 0],
        qformCode: Int16 = 1,
        quaternD: Float = 0
    ) throws -> String? {
        let data = TestMIQFactory.makeNiiWithAffines(
            width: 6, height: 4, depth: 3, datatype: .uint8,
            sformCode: 1,
            srowX: srowX, srowY: srowY, srowZ: [0, 0, 1, 0],
            qformCode: qformCode,
            quaternB: 0, quaternC: 0, quaternD: quaternD, qfac: 1
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
    func swappedAxesNameTheQform() throws {
        #expect(try orientationRow(srowX: [0, 1, 0, 0], srowY: [1, 0, 0, 0]) == "ARS (qform: RAS)")
    }

    @Test
    func roundingDifferencesAreIgnored() throws {
        #expect(try orientationRow(srowX: [0.9999, 0.0001, 0, 0], srowY: [-0.0001, 1.0001, 0, 0]) == "RAS")
    }

    /// An oblique scan rotated ~45° about z: the sform (45.01°) reads ALS, the qform
    /// (44.99°) RAS, but the two transforms are 0.02° apart, so this is no conflict.
    @Test
    func obliqueTieBreakIsIgnored() throws {
        let sformAngle = Float(45.01 * Double.pi / 180)
        let qformAngle = Float(44.99 * Double.pi / 180)
        let row = try orientationRow(
            srowX: [cos(sformAngle), -sin(sformAngle), 0, 0],
            srowY: [sin(sformAngle), cos(sformAngle), 0, 0],
            quaternD: sin(qformAngle / 2)
        )
        #expect(row == "ALS")
    }

    @Test
    func agreeingOrMissingQformShowsOnlyTheCode() throws {
        #expect(try orientationRow(srowX: [1, 0, 0, 0]) == "RAS")
        #expect(try orientationRow(srowX: [-1, 0, 0, 0], qformCode: 0) == "LAS")
    }
}
