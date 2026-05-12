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

    public func centerSlice(plane: SlicePlane, volumeIndex: Int = 0, maxDimension: Int = 512, options: RenderingOptions) -> SliceImage {
        let plan = orientation.plan(for: plane, mode: options.orientation)
        let dims = [width, height, depth]
        let center = max(0, dims[plan.sliceAxis] / 2)
        return slice(plan: plan, index: center, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options)
    }

    /// Renders the center slice for each requested plane using a *shared* intensity window.
    /// Voxels from every grayscale plane are pooled before percentile windowing, so all
    /// returned slices share the same low/high mapping (RGB planes bypass windowing).
    public func centerSlices(
        planes: [SlicePlane] = SlicePlane.allCases,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions
    ) -> [SlicePlane: SliceImage] {
        let dims = [width, height, depth]
        var prepared: [(plane: SlicePlane, slice: PreparedSlice)] = []
        prepared.reserveCapacity(planes.count)
        var pooledFloatCount = 0

        for plane in planes {
            let plan = orientation.plan(for: plane, mode: options.orientation)
            let center = max(0, dims[plan.sliceAxis] / 2)
            let p = prepareSlice(plan: plan, index: center, volumeIndex: volumeIndex)
            if case .grayscale(let values, _, _) = p {
                pooledFloatCount += values.count
            }
            prepared.append((plane, p))
        }

        var pooled = [Float]()
        pooled.reserveCapacity(pooledFloatCount)
        for entry in prepared {
            if case .grayscale(let values, _, _) = entry.slice {
                pooled.append(contentsOf: values)
            }
        }
        let sharedBounds = IntensityWindow.bounds(
            for: pooled,
            lowerPercentile: options.lowerPercentile,
            upperPercentile: options.upperPercentile
        )

        var result: [SlicePlane: SliceImage] = [:]
        result.reserveCapacity(prepared.count)
        for entry in prepared {
            result[entry.plane] = finalize(prepared: entry.slice, bounds: sharedBounds, maxDimension: maxDimension)
        }
        return result
    }

    /// Returns a 3-letter storage orientation label (e.g. "RAS", "LAS") if determinable.
    /// For MIF files this comes from the layout field; for NIfTI/MGH from the sform matrix.
    public func storageOrientationLabel() -> String? {
        orientation.storageLabel()
    }

    /// Display orientation labels for the given view mode. For `.ras`/`.las` the
    /// labels are deterministic per plane; for `.stored` they're affine-derived.
    public func displayOrientation(for plane: SlicePlane, options: RenderingOptions) -> SliceOrientationLabels {
        orientation.plan(for: plane, mode: options.orientation).labels
    }

    public func slice(plane: SlicePlane, index: Int, volumeIndex: Int = 0, maxDimension: Int = 512, options: RenderingOptions) -> SliceImage {
        let plan = orientation.plan(for: plane, mode: options.orientation)
        return slice(plan: plan, index: index, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options)
    }

    private func slice(plan: SliceAxisPlan, index: Int, volumeIndex: Int, maxDimension: Int, options: RenderingOptions) -> SliceImage {
        let prepared = prepareSlice(plan: plan, index: index, volumeIndex: volumeIndex)
        let bounds: IntensityWindow.Bounds?
        if case .grayscale(let values, _, _) = prepared {
            bounds = IntensityWindow.bounds(
                for: values,
                lowerPercentile: options.lowerPercentile,
                upperPercentile: options.upperPercentile
            )
        } else {
            bounds = nil
        }
        return finalize(prepared: prepared, bounds: bounds, maxDimension: maxDimension)
    }

    /// Reads voxel data for a single slice. For grayscale datatypes the buffer is raw
    /// floats (windowing happens later); RGB datatypes produce 8-bit pixel triples directly.
    private enum PreparedSlice {
        case grayscale(values: [Float], config: SliceConfig, maxPhysicalExtent: Float)
        case rgb(pixels: [UInt8], config: SliceConfig, maxPhysicalExtent: Float)
    }

    private func prepareSlice(plan: SliceAxisPlan, index: Int, volumeIndex: Int) -> PreparedSlice {
        let dx = max(1e-6, abs(image.header.pixdim[safe: 1] ?? 1.0))
        let dy = max(1e-6, abs(image.header.pixdim[safe: 2] ?? 1.0))
        let dz = max(1e-6, abs(image.header.pixdim[safe: 3] ?? 1.0))

        let config = SliceConfig(plan: plan, width: width, height: height, depth: depth, dx: dx, dy: dy, dz: dz)
        let maxPhysicalExtent = max(Float(width) * dx, Float(height) * dy, Float(depth) * dz)

        switch image.header.datatype {
        case .rgb24, .rgba32:
            var pixels = [UInt8]()
            pixels.reserveCapacity(config.sliceWidth * config.sliceHeight * 3)
            for row in 0..<config.outerCount {
                for col in 0..<config.innerCount {
                    let coord = config.coordinate(slice: index, row: row, col: col)
                    let (r, g, b) = voxelRGB(x: coord.x, y: coord.y, z: coord.z, t: volumeIndex)
                    pixels.append(r)
                    pixels.append(g)
                    pixels.append(b)
                }
            }
            return .rgb(pixels: pixels, config: config, maxPhysicalExtent: maxPhysicalExtent)

        default:
            var values = [Float]()
            values.reserveCapacity(config.sliceWidth * config.sliceHeight)
            for row in 0..<config.outerCount {
                for col in 0..<config.innerCount {
                    let coord = config.coordinate(slice: index, row: row, col: col)
                    values.append(voxel(x: coord.x, y: coord.y, z: coord.z, t: volumeIndex))
                }
            }
            return .grayscale(values: values, config: config, maxPhysicalExtent: maxPhysicalExtent)
        }
    }

    private func finalize(prepared: PreparedSlice, bounds: IntensityWindow.Bounds?, maxDimension: Int) -> SliceImage {
        switch prepared {
        case .rgb(let pixels, let config, let maxPhysicalExtent):
            let rgbSource = RGBImage(width: config.sliceWidth, height: config.sliceHeight, pixels: pixels)
            return .rgb(rgbSource.resampledForPixelSpacing(
                pixelSpacingX: config.pixelSpacingX,
                pixelSpacingY: config.pixelSpacingY,
                maxPhysicalExtent: maxPhysicalExtent,
                maxDimension: maxDimension
            ))

        case .grayscale(let values, let config, let maxPhysicalExtent):
            let normalized: [UInt8]
            if let bounds {
                normalized = IntensityWindow.apply(values, bounds: bounds)
            } else {
                normalized = Array(repeating: 0, count: values.count)
            }
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
            // RGB slices go through `voxelRGB` in the slicing path; this branch is only reached
            // via the public `voxel()` accessor, where a single Float makes more sense than a tuple.
            // Returns BT.601 luma so the value is at least a meaningful scalar.
            let r = Float(image.byte(atPayloadOffset: byteOffset))
            let g = Float(image.byte(atPayloadOffset: byteOffset + 1))
            let b = Float(image.byte(atPayloadOffset: byteOffset + 2))
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
    }
}

/// Iteration shape and physical pixel spacing for slice extraction, driven by a
/// `SliceAxisPlan` so reorientation modes can swap which storage axis maps to
/// which display axis (and in which direction).
///
/// For "stored" mode the planner emits (sliceAxis=plane-perp, hAxis=in-plane fast,
/// vAxis=in-plane slow, hReversed=false, vReversed=true) which reproduces the
/// pre-reorientation behavior exactly.
private struct SliceConfig {
    let sliceWidth: Int
    let sliceHeight: Int
    let pixelSpacingX: Float
    let pixelSpacingY: Float
    let outerCount: Int
    let innerCount: Int

    private let sliceAxis: Int
    private let hAxis: Int
    private let vAxis: Int
    private let hDim: Int
    private let vDim: Int
    private let hReversed: Bool
    private let vReversed: Bool

    init(plan: SliceAxisPlan, width: Int, height: Int, depth: Int, dx: Float, dy: Float, dz: Float) {
        let dims = [width, height, depth]
        let pixs = [dx, dy, dz]
        self.sliceAxis = plan.sliceAxis
        self.hAxis = plan.hAxis
        self.vAxis = plan.vAxis
        self.hDim = dims[plan.hAxis]
        self.vDim = dims[plan.vAxis]
        self.sliceWidth = self.hDim
        self.sliceHeight = self.vDim
        self.pixelSpacingX = pixs[plan.hAxis]
        self.pixelSpacingY = pixs[plan.vAxis]
        self.outerCount = self.vDim
        self.innerCount = self.hDim
        self.hReversed = plan.hReversed
        self.vReversed = plan.vReversed
    }

    /// `row` is the buffer row (0 = top of image), `col` is the buffer column
    /// (0 = left of image). Maps those to storage (x, y, z) coordinates.
    func coordinate(slice: Int, row: Int, col: Int) -> (x: Int, y: Int, z: Int) {
        var c = [0, 0, 0]
        c[sliceAxis] = slice
        c[hAxis] = hReversed ? (hDim - 1 - col) : col
        c[vAxis] = vReversed ? (vDim - 1 - row) : row
        return (c[0], c[1], c[2])
    }
}
