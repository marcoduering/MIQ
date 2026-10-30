import Foundation
import Testing
@testable import MIQCore

/// `MIQHeader.fileVoxelIndex` must name the voxel MIQ actually reads, in the file's
/// own index terms. The fixtures encode each voxel's file index in its value, so
/// every check is against the file, not against the mapping code.
struct VoxelIndexTests {
    private static func parse(_ data: Data, suffix: String) throws -> MIQVolume {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("miq-voxel-index-\(UUID().uuidString)\(suffix)")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return MIQVolume(image: try MIQParser().parse(url: url))
    }

    @Test(arguments: [["+0", "+1", "+2"], ["+1", "-0", "+2"], ["-2", "+0", "-1"]])
    func mifIndexMatchesMRtrixImageAxes(layout: [String]) throws {
        let (width, height, depth) = (5, 4, 3)
        // The fixture stores MRtrix image voxel (i, j, k) as i + 10j + 100k.
        let volume = try Self.parse(
            TestMIQFactory.makeMif(width: width, height: height, depth: depth, datatype: .int16, layoutTokens: layout),
            suffix: ".mif"
        )
        let header = volume.image.header
        for z in 0..<header.depth {
            for y in 0..<header.height {
                for x in 0..<header.width {
                    let index = header.fileVoxelIndex(x: x, y: y, z: z, t: 0)
                    #expect(index.count == 3)
                    let expected = Float(index[0] + 10 * index[1] + 100 * index[2])
                    #expect(volume.voxel(x: x, y: y, z: z) == expected)
                }
            }
        }
    }

    @Test
    func nrrdIndexLeadsWithItsListAxis() throws {
        let (volumes, width, height, depth) = (3, 4, 3, 2)
        let volume = try Self.parse(
            TestMIQFactory.makeNrrdWithLeadingListAxis(
                volumes: volumes, width: width, height: height, depth: depth, datatype: .float32
            ),
            suffix: ".nrrd"
        )
        let header = volume.image.header
        for t in 0..<volumes {
            for z in 0..<depth {
                for y in 0..<height {
                    for x in 0..<width {
                        let index = header.fileVoxelIndex(x: x, y: y, z: z, t: t)
                        #expect(index == [t, x, y, z])
                        // The fixture's values follow the file's element order.
                        let linear = index[0] + volumes * (index[1] + width * (index[2] + height * index[3]))
                        let expected = Float(TestMIQFactory.sampleValue(index: linear, datatype: .float32))
                        #expect(volume.voxel(x: x, y: y, z: z, t: t) == expected)
                    }
                }
            }
        }
    }

    @Test
    func niftiIndexIsTheCursor() throws {
        let volume = try Self.parse(TestMIQFactory.makeNii(width: 4, height: 3, depth: 2, datatype: .uint8), suffix: ".nii")
        #expect(volume.image.header.fileIndexAxes == nil)
        #expect(volume.image.header.fileVoxelIndex(x: 3, y: 1, z: 0, t: 0) == [3, 1, 0])
    }
}
