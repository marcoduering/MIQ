import Foundation

public struct MIQImage: Sendable {
    public let header: MIQHeader
    public let storage: Data
    public let payloadOffset: Int
    public let payloadBaseElementIndex: Int
    public let payloadElementStrides: [Int]?

    public init(header: MIQHeader, storage: Data, payloadOffset: Int) {
        self.init(
            header: header,
            storage: storage,
            payloadOffset: payloadOffset,
            payloadBaseElementIndex: 0,
            payloadElementStrides: nil
        )
    }

    public init(
        header: MIQHeader,
        storage: Data,
        payloadOffset: Int,
        payloadBaseElementIndex: Int,
        payloadElementStrides: [Int]?
    ) {
        self.header = header
        self.storage = storage
        self.payloadOffset = max(0, payloadOffset)
        self.payloadBaseElementIndex = max(0, payloadBaseElementIndex)
        self.payloadElementStrides = payloadElementStrides
    }

    public var payloadCount: Int {
        return max(0, storage.count - payloadOffset)
    }

    public func byte(atPayloadOffset offset: Int) -> UInt8 {
        return storage[storage.startIndex + payloadOffset + offset]
    }

    /// Element index of voxel (x, y, z, t) within the payload.
    /// Honors signed strides + base for non-canonical layouts (e.g. MIF reversed axes).
    public func voxelElementIndex(x: Int, y: Int, z: Int, t: Int) -> Int {
        if let strides = payloadElementStrides, strides.count >= 4 {
            return payloadBaseElementIndex
                + x * strides[0]
                + y * strides[1]
                + z * strides[2]
                + t * strides[3]
        }
        let spatialIndex = (z * header.height + y) * header.width + x
        let volumeStride = header.width * header.height * header.depth
        return spatialIndex + t * volumeStride
    }
}
