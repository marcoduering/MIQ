import Foundation

public struct MIQIntensityWindowBounds: Sendable, Hashable {
    public let low: Float
    public let high: Float

    public init(low: Float, high: Float) {
        self.low = low
        self.high = high
    }
}

/// Center slices for each plane plus the shared intensity window they were
/// rendered with. Returned by `MIQVolume.centerPreview` so the cold preview path
/// can derive the window and the first-frame images from a single decode.
public struct MIQCenterPreview: Sendable {
    public let slices: [SlicePlane: SliceImage]
    public let windowBounds: MIQIntensityWindowBounds?

    public init(slices: [SlicePlane: SliceImage], windowBounds: MIQIntensityWindowBounds?) {
        self.slices = slices
        self.windowBounds = windowBounds
    }
}

public struct MIQVolumeCursor: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let z: Int
    /// Index along the 4th (volume/time) axis. `coordinate(forAxis:)` deliberately
    /// excludes it — `t` is not a spatial slice axis — but it participates in
    /// `Hashable`/`Equatable` so a timepoint change invalidates a displayed frame.
    public let t: Int

    public init(x: Int, y: Int, z: Int, t: Int = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.t = t
    }

    public func coordinate(forAxis axis: Int) -> Int {
        switch axis {
        case 0: return x
        case 1: return y
        case 2: return z
        default: return 0
        }
    }
}

public struct MIQNormalizedPoint: Sendable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MIQSliceGeometry: Sendable, Hashable {
    public let sliceAxis: Int
    public let horizontalAxis: Int
    public let verticalAxis: Int
    public let width: Int
    public let height: Int
    public let horizontalReversed: Bool
    public let verticalReversed: Bool

    public init(
        sliceAxis: Int,
        horizontalAxis: Int,
        verticalAxis: Int,
        width: Int,
        height: Int,
        horizontalReversed: Bool,
        verticalReversed: Bool
    ) {
        self.sliceAxis = sliceAxis
        self.horizontalAxis = horizontalAxis
        self.verticalAxis = verticalAxis
        self.width = width
        self.height = height
        self.horizontalReversed = horizontalReversed
        self.verticalReversed = verticalReversed
    }
}

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

    public func centerCursor() -> MIQVolumeCursor {
        MIQVolumeCursor(x: max(0, width / 2), y: max(0, height / 2), z: max(0, depth / 2))
    }

    public func sliceGeometry(for plane: SlicePlane, options: RenderingOptions) -> MIQSliceGeometry {
        let plan = orientation.plan(for: plane, mode: options.orientation)
        let dims = [width, height, depth]
        return MIQSliceGeometry(
            sliceAxis: plan.sliceAxis,
            horizontalAxis: plan.hAxis,
            verticalAxis: plan.vAxis,
            width: dims[plan.hAxis],
            height: dims[plan.vAxis],
            horizontalReversed: plan.hReversed,
            verticalReversed: plan.vReversed
        )
    }

    public func sliceIndex(for plane: SlicePlane, cursor: MIQVolumeCursor, options: RenderingOptions) -> Int {
        let geometry = sliceGeometry(for: plane, options: options)
        return cursor.coordinate(forAxis: geometry.sliceAxis)
    }

    public func cursor(
        for plane: SlicePlane,
        sliceIndex: Int,
        normalizedPoint: MIQNormalizedPoint,
        options: RenderingOptions,
        t: Int = 0
    ) -> MIQVolumeCursor {
        let geometry = sliceGeometry(for: plane, options: options)
        let dims = [width, height, depth]
        let safeSlice = Self.clamp(sliceIndex, min: 0, max: max(0, dims[geometry.sliceAxis] - 1))
        let column = Self.discreteIndex(for: normalizedPoint.x, dimension: geometry.width)
        let row = Self.discreteIndex(for: normalizedPoint.y, dimension: geometry.height)

        var coordinates = [0, 0, 0]
        coordinates[geometry.sliceAxis] = safeSlice
        coordinates[geometry.horizontalAxis] = geometry.horizontalReversed ? (geometry.width - 1 - column) : column
        coordinates[geometry.verticalAxis] = geometry.verticalReversed ? (geometry.height - 1 - row) : row
        return MIQVolumeCursor(x: coordinates[0], y: coordinates[1], z: coordinates[2], t: t)
    }

    public func normalizedPoint(for plane: SlicePlane, cursor: MIQVolumeCursor, options: RenderingOptions) -> MIQNormalizedPoint {
        let geometry = sliceGeometry(for: plane, options: options)
        let horizontal = Self.clamp(cursor.coordinate(forAxis: geometry.horizontalAxis), min: 0, max: max(0, geometry.width - 1))
        let vertical = Self.clamp(cursor.coordinate(forAxis: geometry.verticalAxis), min: 0, max: max(0, geometry.height - 1))
        let column = geometry.horizontalReversed ? (geometry.width - 1 - horizontal) : horizontal
        let row = geometry.verticalReversed ? (geometry.height - 1 - vertical) : vertical

        let x = geometry.width > 0 ? (Double(column) + 0.5) / Double(geometry.width) : 0.5
        let y = geometry.height > 0 ? (Double(row) + 0.5) / Double(geometry.height) : 0.5
        return MIQNormalizedPoint(x: x, y: y)
    }

    /// Shared intensity window for the center slices, *without* rendering them.
    /// Used by the cache-hit interactive path, which only needs the window + cursor
    /// to render subsequently scrolled slices — decoding the center slices here and
    /// rendering them would be wasted work on that path.
    public func fixedCenterWindow(
        planes: [SlicePlane] = SlicePlane.allCases,
        volumeIndex: Int = 0,
        options: RenderingOptions
    ) -> MIQIntensityWindowBounds? {
        let bounds = prepareCenterSlices(planes: planes, volumeIndex: volumeIndex, options: options).bounds
        return bounds.map { MIQIntensityWindowBounds(low: $0.low, high: $0.high) }
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

    public func centerSlice(plane: SlicePlane, volumeIndex: Int = 0, maxDimension: Int = 512, options: RenderingOptions) -> SliceImage {
        centerSlice(plane: plane, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: nil)
    }

    public func centerSlice(
        plane: SlicePlane,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions,
        windowBounds: MIQIntensityWindowBounds?
    ) -> SliceImage {
        let plan = orientation.plan(for: plane, mode: options.orientation)
        let dims = [width, height, depth]
        let center = max(0, dims[plan.sliceAxis] / 2)
        return slice(plan: plan, index: center, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: windowBounds)
    }

    /// Renders the center slice for each requested plane using a *shared* intensity
    /// window, and returns that window. Voxels from every grayscale plane are pooled
    /// before percentile windowing, so all returned slices share the same low/high
    /// mapping (RGB planes bypass windowing). The returned `windowBounds` is the
    /// same window subsequently-scrolled slices must reuse for a stable appearance.
    ///
    /// This decodes each center slice exactly once: the pooled buffer used to derive
    /// the window is the same buffer that gets finalized into the returned images.
    public func centerPreview(
        planes: [SlicePlane] = SlicePlane.allCases,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions
    ) -> MIQCenterPreview {
        let (prepared, bounds) = prepareCenterSlices(planes: planes, volumeIndex: volumeIndex, options: options)
        var slices: [SlicePlane: SliceImage] = [:]
        slices.reserveCapacity(prepared.count)
        for entry in prepared {
            slices[entry.plane] = finalize(prepared: entry.slice, bounds: bounds, maxDimension: maxDimension)
        }
        return MIQCenterPreview(
            slices: slices,
            windowBounds: bounds.map { MIQIntensityWindowBounds(low: $0.low, high: $0.high) }
        )
    }

    /// Renders the center slice for each requested plane using a shared intensity window.
    public func centerSlices(
        planes: [SlicePlane] = SlicePlane.allCases,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions
    ) -> [SlicePlane: SliceImage] {
        centerPreview(planes: planes, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options).slices
    }

    /// Decodes the center slice of each requested plane once and derives the shared
    /// percentile window from the pooled grayscale voxels. Single source of truth for
    /// "center slices + their shared window" — `fixedCenterWindow` stops at the bounds,
    /// `centerPreview` continues to finalize the prepared slices.
    private func prepareCenterSlices(
        planes: [SlicePlane],
        volumeIndex: Int,
        options: RenderingOptions
    ) -> (prepared: [(plane: SlicePlane, slice: PreparedSlice)], bounds: IntensityWindow.Bounds?) {
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
        let bounds = IntensityWindow.bounds(
            for: pooled,
            lowerPercentile: options.lowerPercentile,
            upperPercentile: options.upperPercentile
        )
        return (prepared, bounds)
    }

    /// Returns a 3-letter storage orientation label (e.g. "RAS", "LAS") if determinable.
    /// For MIF files this comes from the layout field; for NIfTI/MGH from the sform matrix.
    public func storageOrientationLabel() -> String? {
        orientation.storageLabel()
    }

    /// Display orientation labels for the given view mode. For the reoriented modes
    /// the labels are deterministic per plane; for `.stored` they're affine-derived.
    public func displayOrientation(for plane: SlicePlane, options: RenderingOptions) -> SliceOrientationLabels {
        orientation.plan(for: plane, mode: options.orientation).labels
    }

    public func slice(plane: SlicePlane, index: Int, volumeIndex: Int = 0, maxDimension: Int = 512, options: RenderingOptions) -> SliceImage {
        slice(plane: plane, index: index, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: nil)
    }

    public func slice(
        plane: SlicePlane,
        index: Int,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions,
        windowBounds: MIQIntensityWindowBounds?
    ) -> SliceImage {
        let plan = orientation.plan(for: plane, mode: options.orientation)
        return slice(plan: plan, index: index, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: windowBounds)
    }

    private func slice(
        plan: SliceAxisPlan,
        index: Int,
        volumeIndex: Int,
        maxDimension: Int,
        options: RenderingOptions,
        windowBounds: MIQIntensityWindowBounds?
    ) -> SliceImage {
        let dims = [width, height, depth]
        let safeIndex = Self.clamp(index, min: 0, max: max(0, dims[plan.sliceAxis] - 1))
        let prepared = prepareSlice(plan: plan, index: safeIndex, volumeIndex: volumeIndex)
        let bounds: IntensityWindow.Bounds?
        if let windowBounds {
            bounds = IntensityWindow.Bounds(low: windowBounds.low, high: windowBounds.high)
        } else if case .grayscale(let values, _, _) = prepared {
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

        // Hot path. This is intentionally a faster re-expression of the public
        // `voxel()` accessor (and the analogous RGB byte read): the per-voxel
        // datatype switch is hoisted out of the loop (one typed reader chosen up
        // front) and the payload is read through a single `withUnsafeBytes` raw
        // pointer instead of `Data` byte subscripting. Output must stay
        // bit-identical to `voxel()` — it remains the public API and the
        // correctness reference (the test suite renders slices across every
        // datatype / endianness / MIF stride layout and compares pixels, and
        // also asserts `voxel()` directly). x/y/z from `SliceConfig.coordinate`
        // are always in range; only the `t` and byte-range guards remain.
        let datatype = image.header.datatype
        let bpv = datatype.bytesPerVoxel
        let payloadCount = image.payloadCount
        let payloadBase = image.payloadOffset
        let le = image.header.littleEndian
        let slope = image.header.sclSlope
        let intercept = image.header.sclInter
        let applyScale = slope != 0
        let tInRange = volumeIndex >= 0 && volumeIndex < volumes
        let sampleCount = config.sliceWidth * config.sliceHeight
        let rowCount = config.outerCount
        let colCount = config.innerCount

        switch datatype {
        case .rgb24, .rgba32:
            // RGB read: ignore alpha (preview is opaque), guard with literal 3
            // (not bpv, so rgba32's 4th byte is never required), zero on miss.
            let pixels = [UInt8](unsafeUninitializedCapacity: sampleCount * 3) { buf, initialized in
                if !tInRange {
                    for i in 0..<(sampleCount * 3) { buf[i] = 0 }
                    initialized = sampleCount * 3
                    return
                }
                image.storage.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
                    var w = 0
                    for row in 0..<rowCount {
                        for col in 0..<colCount {
                            let coord = config.coordinate(slice: index, row: row, col: col)
                            let elemIndex = image.voxelElementIndex(x: coord.x, y: coord.y, z: coord.z, t: volumeIndex)
                            let byteOffset = elemIndex * bpv
                            if byteOffset < 0 || byteOffset + 3 > payloadCount {
                                buf[w] = 0; buf[w + 1] = 0; buf[w + 2] = 0
                            } else {
                                let abs = payloadBase + byteOffset
                                buf[w] = rawBuf.loadUnaligned(fromByteOffset: abs, as: UInt8.self)
                                buf[w + 1] = rawBuf.loadUnaligned(fromByteOffset: abs + 1, as: UInt8.self)
                                buf[w + 2] = rawBuf.loadUnaligned(fromByteOffset: abs + 2, as: UInt8.self)
                            }
                            w += 3
                        }
                    }
                }
                initialized = sampleCount * 3
            }
            return .rgb(pixels: pixels, config: config, maxPhysicalExtent: maxPhysicalExtent)

        default:
            // Typed reader chosen once; mirrors `rawVoxelValue` arm-for-arm.
            // `le ? u : u.byteSwapped` reproduces MIQBinaryReader's manual
            // little/big-endian byte assembly on this little-endian host.
            let read: (UnsafeRawBufferPointer, Int) -> Float
            switch datatype {
            case .uint8:
                read = { Float($0.loadUnaligned(fromByteOffset: $1, as: UInt8.self)) }
            case .int8:
                read = { Float(Int8(bitPattern: $0.loadUnaligned(fromByteOffset: $1, as: UInt8.self))) }
            case .int16:
                read = { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt16.self); return Float(Int16(bitPattern: le ? u : u.byteSwapped)) }
            case .uint16:
                read = { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt16.self); return Float(le ? u : u.byteSwapped) }
            case .int32:
                read = { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt32.self); return Float(Int32(bitPattern: le ? u : u.byteSwapped)) }
            case .uint32:
                read = { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt32.self); return Float(le ? u : u.byteSwapped) }
            case .float32:
                read = { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt32.self); return Float(bitPattern: le ? u : u.byteSwapped) }
            case .float64:
                read = { let u = $0.loadUnaligned(fromByteOffset: $1, as: UInt64.self); return Float(Double(bitPattern: le ? u : u.byteSwapped)) }
            case .rgb24, .rgba32:
                read = { _, _ in 0 } // unreachable: handled by the RGB case above
            }

            let values = [Float](unsafeUninitializedCapacity: sampleCount) { buf, initialized in
                if !tInRange {
                    for i in 0..<sampleCount { buf[i] = 0 }
                    initialized = sampleCount
                    return
                }
                image.storage.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
                    var w = 0
                    for row in 0..<rowCount {
                        for col in 0..<colCount {
                            let coord = config.coordinate(slice: index, row: row, col: col)
                            let elemIndex = image.voxelElementIndex(x: coord.x, y: coord.y, z: coord.z, t: volumeIndex)
                            let byteOffset = elemIndex * bpv
                            let v: Float
                            if byteOffset < 0 || byteOffset + bpv > payloadCount {
                                v = 0
                            } else {
                                let raw = read(rawBuf, payloadBase + byteOffset)
                                v = applyScale ? raw * slope + intercept : raw
                            }
                            buf[w] = v
                            w += 1
                        }
                    }
                }
                initialized = sampleCount
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
            // RGB slices are rendered by the dedicated RGB reader in `prepareSlice`;
            // this branch is only reached via the public `voxel()` accessor, where a
            // single Float makes more sense than a tuple. Returns BT.601 luma so the
            // value is at least a meaningful scalar.
            let r = Float(image.byte(atPayloadOffset: byteOffset))
            let g = Float(image.byte(atPayloadOffset: byteOffset + 1))
            let b = Float(image.byte(atPayloadOffset: byteOffset + 2))
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
    }

    private static func discreteIndex(for normalized: Double, dimension: Int) -> Int {
        guard dimension > 1 else { return 0 }
        let clamped = max(0, min(1, normalized))
        return clamp(Int((clamped * Double(dimension)).rounded(.down)), min: 0, max: dimension - 1)
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
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
