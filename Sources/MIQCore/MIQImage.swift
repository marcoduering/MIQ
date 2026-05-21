import Foundation

public struct MIQImage: Sendable {
    public let header: MIQHeader
    public let storage: Data
    public let payloadOffset: Int
    /// Per-axis element strides for non-canonical storage layouts (e.g. MIF
    /// permuted axes, NRRD column-vs-row order). `nil` means canonical
    /// x-fastest layout. Strides are always positive — axis-reversal info
    /// lives in `MIQHeader.orientationFrame` and feeds display labels, not
    /// voxel addressing.
    public let payloadElementStrides: [Int]?

    public init(
        header: MIQHeader,
        storage: Data,
        payloadOffset: Int,
        payloadElementStrides: [Int]? = nil
    ) {
        self.header = header
        self.storage = storage
        self.payloadOffset = max(0, payloadOffset)
        self.payloadElementStrides = payloadElementStrides
    }

    public var payloadCount: Int {
        return max(0, storage.count - payloadOffset)
    }

    public func byte(atPayloadOffset offset: Int) -> UInt8 {
        return storage[storage.startIndex + payloadOffset + offset]
    }

    /// Element index of voxel (x, y, z, t) within the payload.
    public func voxelElementIndex(x: Int, y: Int, z: Int, t: Int) -> Int {
        if let strides = payloadElementStrides, strides.count >= 4 {
            return x * strides[0]
                + y * strides[1]
                + z * strides[2]
                + t * strides[3]
        }
        let spatialIndex = (z * header.height + y) * header.width + x
        let volumeStride = header.width * header.height * header.depth
        return spatialIndex + t * volumeStride
    }
}
