import Foundation

public struct MIQVolume: Sendable {
    public let image: MIQImage
    private let orientation: OrientationResolver

    public init(image: MIQImage) {
        self.image = image
        self.orientation = OrientationResolver(image: image)
    }

    public var width: Int { image.header.width }
    public var height: Int { image.header.height }
    public var depth: Int { image.header.depth }
    public var volumes: Int { image.header.volumes }

    public var centerIndices: (x: Int, y: Int, z: Int) {
        return (max(0, width / 2), max(0, height / 2), max(0, depth / 2))
    }

    public func voxel(x: Int, y: Int, z: Int, t: Int = 0) -> Float {
        guard x >= 0, x < width,
              y >= 0, y < height,
              z >= 0, z < depth,
              t >= 0, t < volumes else {
            return 0
        }

        let voxelIndex = image.voxelElementIndex(x: x, y: y, z: z, t: t)
        let bytesPerVoxel = image.header.datatype.bytesPerVoxel
        let byteOffset = voxelIndex * bytesPerVoxel

        if byteOffset < 0 || byteOffset + bytesPerVoxel > image.payloadCount {
            return 0
        }

        let raw = rawVoxelValue(byteOffset: byteOffset)

        let slope = image.header.sclSlope
        let intercept = image.header.sclInter
        if slope != 0 {
            return raw * slope + intercept
        }
        return raw
    }

    public func centerSlice(plane: SlicePlane, volumeIndex: Int = 0, maxDimension: Int = 512) -> SliceImage {
        let centers = centerIndices
        let center: Int
        switch plane {
        case .coronal: center = centers.y
        case .sagittal: center = centers.x
        case .axial: center = centers.z
        }
        return slice(plane: plane, index: center, volumeIndex: volumeIndex, maxDimension: maxDimension)
    }

    /// Returns a 3-letter storage orientation label (e.g. "RAS", "LAS") if determinable.
    /// For MIF files this comes from the layout field; for NIfTI/MGH from the sform matrix.
    public func storageOrientationLabel() -> String? {
        orientation.storageLabel()
    }

    public func displayOrientation(for plane: SlicePlane) -> SliceOrientationLabels {
        orientation.displayOrientation(for: plane)
    }

    public func slice(plane: SlicePlane, index: Int, volumeIndex: Int = 0, maxDimension: Int = 512) -> SliceImage {
        let dx = max(1e-6, abs(image.header.pixdim[safe: 1] ?? 1.0))
        let dy = max(1e-6, abs(image.header.pixdim[safe: 2] ?? 1.0))
        let dz = max(1e-6, abs(image.header.pixdim[safe: 3] ?? 1.0))

        let config = SliceConfig(plane: plane, width: width, height: height, depth: depth, dx: dx, dy: dy, dz: dz)
        let maxPhysicalExtent = max(Float(width) * dx, Float(height) * dy, Float(depth) * dz)

        switch image.header.datatype {
        case .rgb24, .rgba32:
            var pixels = [UInt8]()
            pixels.reserveCapacity(config.sliceWidth * config.sliceHeight * 3)
            for outer in config.outerRange {
                for inner in 0..<config.innerCount {
                    let coord = config.coordinate(slice: index, outer: outer, inner: inner)
                    let (r, g, b) = voxelRGB(x: coord.x, y: coord.y, z: coord.z, t: volumeIndex)
                    pixels.append(r)
                    pixels.append(g)
                    pixels.append(b)
                }
            }
            let rgbSource = RGBImage(width: config.sliceWidth, height: config.sliceHeight, pixels: pixels)
            return .rgb(rgbSource.resampledForPixelSpacing(
                pixelSpacingX: config.pixelSpacingX,
                pixelSpacingY: config.pixelSpacingY,
                maxPhysicalExtent: maxPhysicalExtent,
                maxDimension: maxDimension
            ))

        default:
            var values = [Float]()
            values.reserveCapacity(config.sliceWidth * config.sliceHeight)
            for outer in config.outerRange {
                for inner in 0..<config.innerCount {
                    let coord = config.coordinate(slice: index, outer: outer, inner: inner)
                    values.append(voxel(x: coord.x, y: coord.y, z: coord.z, t: volumeIndex))
                }
            }
            let normalized = IntensityWindow.normalize(values)
            let graySource = GrayscaleImage(width: config.sliceWidth, height: config.sliceHeight, pixels: normalized)
            return .grayscale(graySource.resampledForPixelSpacing(
                pixelSpacingX: config.pixelSpacingX,
                pixelSpacingY: config.pixelSpacingY,
                maxPhysicalExtent: maxPhysicalExtent,
                maxDimension: maxDimension
            ))
        }
    }

    private func voxelRGB(x: Int, y: Int, z: Int, t: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        guard x >= 0, x < width,
              y >= 0, y < height,
              z >= 0, z < depth,
              t >= 0, t < volumes else {
            return (0, 0, 0)
        }

        let voxelIndex = image.voxelElementIndex(x: x, y: y, z: z, t: t)
        let byteOffset = voxelIndex * image.header.datatype.bytesPerVoxel

        // Alpha is intentionally ignored for rgba32 — the preview is opaque.
        guard byteOffset >= 0, byteOffset + 3 <= image.payloadCount else {
            return (0, 0, 0)
        }

        return (
            image.byte(atPayloadOffset: byteOffset),
            image.byte(atPayloadOffset: byteOffset + 1),
            image.byte(atPayloadOffset: byteOffset + 2)
        )
    }

    private func rawVoxelValue(byteOffset: Int) -> Float {
        let bytesNeeded = image.header.datatype.bytesPerVoxel
        guard byteOffset >= 0, byteOffset + bytesNeeded <= image.payloadCount else {
            return 0
        }
        let absOffset = image.payloadOffset + byteOffset
        let le = image.header.littleEndian
        switch image.header.datatype {
        case .uint8:
            return Float(image.byte(atPayloadOffset: byteOffset))
        case .int8:
            return Float(Int8(bitPattern: image.byte(atPayloadOffset: byteOffset)))
        case .int16:
            return Float(Int16(bitPattern: MIQBinaryReader.uint16(image.storage, absOffset, littleEndian: le)))
        case .uint16:
            return Float(MIQBinaryReader.uint16(image.storage, absOffset, littleEndian: le))
        case .int32:
            return Float(Int32(bitPattern: MIQBinaryReader.uint32(image.storage, absOffset, littleEndian: le)))
        case .uint32:
            return Float(MIQBinaryReader.uint32(image.storage, absOffset, littleEndian: le))
        case .float32:
            return Float(bitPattern: MIQBinaryReader.uint32(image.storage, absOffset, littleEndian: le))
        case .float64:
            return Float(Double(bitPattern: MIQBinaryReader.uint64(image.storage, absOffset, littleEndian: le)))
        case .rgb24, .rgba32:
            let r = Float(image.byte(atPayloadOffset: byteOffset))
            let g = Float(image.byte(atPayloadOffset: byteOffset + 1))
            let b = Float(image.byte(atPayloadOffset: byteOffset + 2))
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
    }
}

/// Per-plane iteration shape and physical pixel spacing for slice extraction.
private struct SliceConfig {
    let sliceWidth: Int
    let sliceHeight: Int
    let pixelSpacingX: Float
    let pixelSpacingY: Float
    let outerRange: ReversedCollection<Range<Int>>
    let innerCount: Int
    private let plane: SlicePlane

    init(plane: SlicePlane, width: Int, height: Int, depth: Int, dx: Float, dy: Float, dz: Float) {
        self.plane = plane
        switch plane {
        case .coronal:
            sliceWidth = width
            sliceHeight = depth
            pixelSpacingX = dx
            pixelSpacingY = dz
            outerRange = (0..<depth).reversed()
            innerCount = width
        case .sagittal:
            sliceWidth = height
            sliceHeight = depth
            pixelSpacingX = dy
            pixelSpacingY = dz
            outerRange = (0..<depth).reversed()
            innerCount = height
        case .axial:
            sliceWidth = width
            sliceHeight = height
            pixelSpacingX = dx
            pixelSpacingY = dy
            outerRange = (0..<height).reversed()
            innerCount = width
        }
    }

    func coordinate(slice: Int, outer: Int, inner: Int) -> (x: Int, y: Int, z: Int) {
        switch plane {
        case .coronal: return (x: inner, y: slice, z: outer)
        case .sagittal: return (x: slice, y: inner, z: outer)
        case .axial: return (x: inner, y: outer, z: slice)
        }
    }
}
