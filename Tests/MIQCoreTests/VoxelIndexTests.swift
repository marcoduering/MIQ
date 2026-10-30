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

    /// A size-1 list axis is still one of the file's axes: the index keeps its 0
    /// (and indexing past a 3-value result used to trap).
    @Test
    func nrrdIndexKeepsASizeOneListAxis() throws {
        let volume = try Self.parse(
            TestMIQFactory.makeNrrdWithLeadingListAxis(volumes: 1, width: 4, height: 3, depth: 2, datatype: .float32),
            suffix: ".nrrd"
        )
        #expect(volume.image.header.fileVoxelIndex(x: 3, y: 1, z: 1, t: 0) == [0, 3, 1, 1])
    }

    /// 4D layouts with the volume axis reversed or stored fastest (volume-interleaved,
    /// as MRtrix writes DWI). The payload is laid out here from MRtrix's layout rule
    /// directly, not through `MIFAxisLayout`, so the parser is checked against an
    /// independent writer.
    @Test(arguments: [["+0", "+1", "+2", "-3"], ["+1", "+2", "+3", "+0"], ["-2", "+3", "+1", "-0"]])
    func mif4DIndexMatchesMRtrixImageAxes(layout: [String]) throws {
        let dims = [4, 3, 2, 3]
        let volume = try Self.parse(Self.makeMif4D(dims: dims, layout: layout), suffix: ".mif")
        let header = volume.image.header
        for t in 0..<header.volumes {
            for z in 0..<header.depth {
                for y in 0..<header.height {
                    for x in 0..<header.width {
                        let index = header.fileVoxelIndex(x: x, y: y, z: z, t: t)
                        #expect(index.count == 4)
                        let expected = Float(index[0] + 10 * index[1] + 100 * index[2] + 1000 * index[3])
                        #expect(volume.voxel(x: x, y: y, z: z, t: t) == expected)
                    }
                }
            }
        }
    }

    /// Int16 MIF storing image voxel (i, j, k, v) as i + 10j + 100k + 1000v. Per MRtrix,
    /// `|layout[a]|` ranks axis `a` (0 = fastest) and a `-` stores it from its last
    /// voxel to its first.
    private static func makeMif4D(dims: [Int], layout: [String]) -> Data {
        let ranks = layout.map { abs(Int($0)!) }
        let reversed = layout.map { $0.hasPrefix("-") }
        var payload = [UInt8](repeating: 0, count: dims.reduce(1, *) * 2)
        for v in 0..<dims[3] {
            for k in 0..<dims[2] {
                for j in 0..<dims[1] {
                    for i in 0..<dims[0] {
                        let voxel = [i, j, k, v]
                        var element = 0
                        for axis in 0..<4 {
                            let faster = (0..<4).filter { ranks[$0] < ranks[axis] }
                            let stride = faster.reduce(1) { $0 * dims[$1] }
                            let position = reversed[axis] ? dims[axis] - 1 - voxel[axis] : voxel[axis]
                            element += position * stride
                        }
                        let value = UInt16(i + 10 * j + 100 * k + 1000 * v)
                        payload[element * 2] = UInt8(value & 0xFF)
                        payload[element * 2 + 1] = UInt8(value >> 8)
                    }
                }
            }
        }
        var offset = 0
        var header = ""
        while true {
            header = """
            mrtrix image
            dim: \(dims.map(String.init).joined(separator: ","))
            vox: 1,1,1,1
            layout: \(layout.joined(separator: ","))
            datatype: Int16LE
            file: . \(offset)
            END

            """
            if header.utf8.count == offset { break }
            offset = header.utf8.count
        }
        return Data(header.utf8) + Data(payload)
    }

    @Test
    func niftiIndexIsTheCursor() throws {
        let volume = try Self.parse(TestMIQFactory.makeNii(width: 4, height: 3, depth: 2, datatype: .uint8), suffix: ".nii")
        #expect(volume.image.header.fileIndexAxes == nil)
        #expect(volume.image.header.fileVoxelIndex(x: 3, y: 1, z: 0, t: 0) == [3, 1, 0])
    }
}
