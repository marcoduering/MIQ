import Foundation

public struct MIQHeader: Sendable {
    public let littleEndian: Bool
    public let dimensions: [Int]
    public let pixdim: [Float]
    public let datatype: MIQDatatype
    public let voxOffset: Int
    public let sclSlope: Float
    public let sclInter: Float
    public let qformCode: Int
    public let sformCode: Int
    public let srowX: [Float]
    public let srowY: [Float]
    public let srowZ: [Float]

    public var width: Int { dimensions[safe: 0] ?? 0 }
    public var height: Int { dimensions[safe: 1] ?? 0 }
    public var depth: Int { dimensions[safe: 2] ?? 1 }
    public var volumes: Int { max(1, dimensions[safe: 3] ?? 1) }

    public init(
        littleEndian: Bool,
        dimensions: [Int],
        pixdim: [Float],
        datatype: MIQDatatype,
        voxOffset: Int,
        sclSlope: Float,
        sclInter: Float,
        qformCode: Int,
        sformCode: Int,
        srowX: [Float],
        srowY: [Float],
        srowZ: [Float]
    ) {
        self.littleEndian = littleEndian
        self.dimensions = dimensions
        self.pixdim = pixdim
        self.datatype = datatype
        self.voxOffset = voxOffset
        self.sclSlope = sclSlope
        self.sclInter = sclInter
        self.qformCode = qformCode
        self.sformCode = sformCode
        self.srowX = srowX
        self.srowY = srowY
        self.srowZ = srowZ
    }
}
