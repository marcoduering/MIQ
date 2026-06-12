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
/// When a segmentation LUT was detected, `windowBounds` is `nil` (LUT replaces
/// windowing) and `segmentationLut` carries the shared label→RGB table.
public struct MIQCenterPreview: Sendable {
    public let slices: [SlicePlane: SliceImage]
    public let windowBounds: MIQIntensityWindowBounds?
    /// Non-nil when the volume was detected as a label segmentation. Build once
    /// and pass to every subsequent `MIQVolume.slice(…lut:)` call so label colours
    /// stay consistent across planes, slices, and timepoints.
    public let segmentationLut: SegmentationLut?

    public init(
        slices: [SlicePlane: SliceImage],
        windowBounds: MIQIntensityWindowBounds?,
        segmentationLut: SegmentationLut? = nil
    ) {
        self.slices = slices
        self.windowBounds = windowBounds
        self.segmentationLut = segmentationLut
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

    /// `false` when the backing payload holds fewer volumes than the header
    /// declares — i.e. it was loaded with the volume-0 cap (a 4D `.nii.gz` cold
    /// load, or *any* 4D NIfTI on a network volume via the bounded-prefix read).
    /// The preview layer uses this to decide whether stepping into 4D needs a full
    /// re-parse, instead of keying off the file kind (which misses the bounded
    /// uncompressed `.nii` case). Only meaningful for canonical x-fastest layouts;
    /// strided kinds (MIF/NRRD) are never capped, so they always report `true`.
    public var containsAllVolumes: Bool {
        guard image.payloadElementStrides == nil else { return true }
        let bytesPerVolume = width * height * depth * image.header.datatype.bytesPerVoxel
        guard bytesPerVolume > 0 else { return true }
        return image.payloadCount / bytesPerVolume >= volumes
    }

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

    /// The interactive-state inputs — segmentation LUT (if any) and the shared
    /// window bounds — derived from a *single* decode of volume 0's three center
    /// slices. Equivalent to `buildSegmentationLut(options:)` followed by
    /// `fixedCenterWindow(volumeIndex: 0, options:)`, but without the second
    /// decode those two would each perform. When a LUT is active, windowing is
    /// replaced, so `windowBounds` is `nil` (matching `centerPreview`).
    public func centerInteractiveState(
        options: RenderingOptions
    ) -> (windowBounds: MIQIntensityWindowBounds?, segmentationLut: SegmentationLut?) {
        let (prepared, bounds) = prepareCenterSlices(planes: SlicePlane.allCases, volumeIndex: 0, options: options)
        if let lut = buildSegmentationLut(options: options, preparedCenterSlices: prepared) {
            return (nil, lut)
        }
        return (bounds.map { MIQIntensityWindowBounds(low: $0.low, high: $0.high) }, nil)
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
        centerSlice(plane: plane, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: nil, lut: nil)
    }

    public func centerSlice(
        plane: SlicePlane,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions,
        windowBounds: MIQIntensityWindowBounds?,
        lut: SegmentationLut? = nil
    ) -> SliceImage {
        let plan = orientation.plan(for: plane, mode: options.orientation)
        let dims = [width, height, depth]
        let center = max(0, dims[plan.sliceAxis] / 2)
        return slice(plan: plan, index: center, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: windowBounds, lut: lut)
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
        // Decode the center slices once, then detect segmentation from the very
        // same decoded buffers instead of decoding a second time. Detection is
        // defined over volume 0's three center planes, so reuse only when this
        // preview is exactly that (the production cold-load call); any other
        // shape falls back to the self-decoding path. When a LUT is active it
        // replaces percentile windowing entirely; the bounds are still computed
        // for callers that need the window independently (non-label mode).
        let (prepared, bounds) = prepareCenterSlices(planes: planes, volumeIndex: volumeIndex, options: options)
        let lut = (volumeIndex == 0 && planes == SlicePlane.allCases)
            ? buildSegmentationLut(options: options, preparedCenterSlices: prepared)
            : buildSegmentationLut(options: options)
        var slices: [SlicePlane: SliceImage] = [:]
        slices.reserveCapacity(prepared.count)
        for entry in prepared {
            slices[entry.plane] = finalize(prepared: entry.slice, bounds: bounds, maxDimension: maxDimension, lut: lut)
        }
        return MIQCenterPreview(
            slices: slices,
            windowBounds: lut == nil ? bounds.map { MIQIntensityWindowBounds(low: $0.low, high: $0.high) } : nil,
            segmentationLut: lut
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
        slice(plane: plane, index: index, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: nil, lut: nil)
    }

    public func slice(
        plane: SlicePlane,
        index: Int,
        volumeIndex: Int = 0,
        maxDimension: Int = 512,
        options: RenderingOptions,
        windowBounds: MIQIntensityWindowBounds?,
        lut: SegmentationLut? = nil
    ) -> SliceImage {
        let plan = orientation.plan(for: plane, mode: options.orientation)
        return slice(plan: plan, index: index, volumeIndex: volumeIndex, maxDimension: maxDimension, options: options, windowBounds: windowBounds, lut: lut)
    }

    private func slice(
        plan: SliceAxisPlan,
        index: Int,
        volumeIndex: Int,
        maxDimension: Int,
        options: RenderingOptions,
        windowBounds: MIQIntensityWindowBounds?,
        lut: SegmentationLut? = nil
    ) -> SliceImage {
        let dims = [width, height, depth]
        let safeIndex = Self.clamp(index, min: 0, max: max(0, dims[plan.sliceAxis] - 1))
        let prepared = prepareSlice(plan: plan, index: safeIndex, volumeIndex: volumeIndex)
        let bounds: IntensityWindow.Bounds?
        if lut != nil {
            bounds = nil
        } else if let windowBounds {
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
        return finalize(prepared: prepared, bounds: bounds, maxDimension: maxDimension, lut: lut)
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

    private func finalize(prepared: PreparedSlice, bounds: IntensityWindow.Bounds?, maxDimension: Int, lut: SegmentationLut? = nil) -> SliceImage {
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
            if let lut {
                // Label path: map each rounded voxel value through the LUT → RGB.
                // Nearest-neighbour resampling (labels must never be interpolated).
                let pixelCount = values.count
                let rgb = [UInt8](unsafeUninitializedCapacity: pixelCount * 3) { buf, initialized in
                    var w = 0
                    for v in values {
                        let label = v.isFinite ? Int(v.rounded()) : 0
                        let c = lut.lookup(label)
                        buf[w] = c.r; buf[w + 1] = c.g; buf[w + 2] = c.b
                        w += 3
                    }
                    initialized = pixelCount * 3
                }
                let rgbSource = RGBImage(width: config.sliceWidth, height: config.sliceHeight, pixels: rgb)
                return .rgb(rgbSource.resampledForPixelSpacing(
                    pixelSpacingX: config.pixelSpacingX,
                    pixelSpacingY: config.pixelSpacingY,
                    maxPhysicalExtent: maxPhysicalExtent,
                    maxDimension: maxDimension
                ))
            }
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

    // MARK: - Segmentation LUT

    /// Decides whether this volume should be rendered as a coloured segmentation
    /// and builds the shared label→RGB LUT. Returns `nil` (→ percentile windowing)
    /// when colouring is `.off`, the datatype/scaling is intensity-like, or the
    /// sampled center slices don't look like integer labels.
    ///
    /// Detection is conservative: integer/float datatypes with identity scaling
    /// only; every sampled center-slice value must be integral (|v - round(v)| ≤
    /// 1e-3); distinct-label count must stay < `maxLabels` (default 160). A genuine
    /// float intensity image has continuous values and fails the integrality check.
    ///
    /// `maxLabels` is exposed for testing with small fixtures; production callers
    /// use the default.
    public func buildSegmentationLut(options: RenderingOptions, maxLabels: Int = 160) -> SegmentationLut? {
        guard segmentationDetectionEligible(options: options) else { return nil }

        var labelSet = Set<Int>()
        let dims = [width, height, depth]
        for plane in SlicePlane.allCases {
            let plan = orientation.plan(for: plane, mode: options.orientation)
            let center = max(0, dims[plan.sliceAxis] / 2)
            guard case .grayscale(let values, _, _) = prepareSlice(plan: plan, index: center, volumeIndex: 0) else {
                return nil
            }
            guard collectLabels(values, into: &labelSet, maxLabels: maxLabels) else { return nil }
        }
        return finishSegmentationLut(labelSet: labelSet, options: options)
    }

    /// Same detection as `buildSegmentationLut(options:)`, but reading the label
    /// values from center slices the caller already decoded instead of decoding
    /// them a second time. The caller (`centerPreview`) must pass volume 0's
    /// three center planes — the only configuration detection is defined over —
    /// so the result is identical to the self-decoding path.
    private func buildSegmentationLut(
        options: RenderingOptions,
        preparedCenterSlices prepared: [(plane: SlicePlane, slice: PreparedSlice)],
        maxLabels: Int = 160
    ) -> SegmentationLut? {
        guard segmentationDetectionEligible(options: options) else { return nil }

        var labelSet = Set<Int>()
        for entry in prepared {
            guard case .grayscale(let values, _, _) = entry.slice else { return nil }
            guard collectLabels(values, into: &labelSet, maxLabels: maxLabels) else { return nil }
        }
        return finishSegmentationLut(labelSet: labelSet, options: options)
    }

    /// Cheap pre-decode gate: colouring enabled, datatype not already RGB, and
    /// identity intensity scaling. Lets callers skip the center-slice decode
    /// entirely when this volume can't be a label segmentation.
    private func segmentationDetectionEligible(options: RenderingOptions) -> Bool {
        guard options.segmentationColoring != .off else { return false }
        let datatype = image.header.datatype
        guard datatype != .rgb24, datatype != .rgba32 else { return false }
        let slope = image.header.sclSlope
        let inter = image.header.sclInter
        return (slope == 0 || slope == 1) && inter == 0
    }

    /// Folds one center slice's voxels into the running label set. Returns
    /// `false` (→ not a label volume) the instant a value is non-integral or the
    /// distinct-label count exceeds `maxLabels`. Order-independent, so pooling
    /// across planes in any order yields the same set.
    private func collectLabels(_ values: [Float], into labelSet: inout Set<Int>, maxLabels: Int) -> Bool {
        for v in values {
            guard v.isFinite else { continue }
            let rounded = Int(v.rounded())
            guard abs(v - Float(rounded)) <= 1e-3 else { return false }
            labelSet.insert(rounded)
            if labelSet.count > maxLabels { return false }
        }
        return true
    }

    /// Final LUT selection from a collected label set (background removed here):
    /// empty ⇒ nil; a lone label confirmed against the full volume ⇒ binary mask
    /// (or `nil`/multi-label per the scan); otherwise FreeSurfer or random.
    private func finishSegmentationLut(labelSet: Set<Int>, options: RenderingOptions) -> SegmentationLut? {
        var labelSet = labelSet
        labelSet.remove(0)
        guard !labelSet.isEmpty else { return nil }

        if labelSet.count == 1 {
            let centerLabel = labelSet.first!
            switch confirmBinaryMask(centerLabel: centerLabel) {
            case .intensity:
                return nil
            case .binary:
                return SegmentationLut(kind: .monochromeWhite)
            case .multiLabel:
                break // fall through: colour as normal label volume
            }
        }

        let useFreeSurfer = options.segmentationColoring == .auto
            && SegmentationLut.looksLikeFreeSurfer(labelSet)
        return SegmentationLut(kind: useFreeSurfer ? .freeSurfer : .random)
    }

    private enum BinaryCheckResult { case binary, multiLabel, intensity }

    /// Confirms whether a volume with exactly one foreground label in the center
    /// slices is truly binary by scanning volume 0 in full.
    /// Returns `.multiLabel` or `.intensity` the instant a disqualifying voxel
    /// appears; only a true binary mask completes the scan.
    ///
    /// For row-major layouts (nil `payloadElementStrides`) volume 0 is the first N
    /// contiguous elements — scanned with the datatype switch hoisted out of the
    /// loop, integers compared directly (no per-voxel index math, no float convert
    /// for integer data). MIF custom strides fall back to the correct per-voxel walk.
    private func confirmBinaryMask(centerLabel: Int) -> BinaryCheckResult {
        if image.payloadElementStrides != nil {
            return confirmBinaryMaskPerVoxel(centerLabel: centerLabel)
        }

        let datatype = image.header.datatype
        let bpv = datatype.bytesPerVoxel
        let voxelCount = width * height * depth
        guard voxelCount > 0 else { return .binary }
        let elemCount = min(voxelCount, image.payloadCount / max(bpv, 1))
        let le = image.header.littleEndian
        let base = image.payloadOffset

        return image.storage.withUnsafeBytes { rawBuf -> BinaryCheckResult in
            switch datatype {
            case .int8:
                for i in 0..<elemCount {
                    let v = Int(Int8(bitPattern: rawBuf.loadUnaligned(fromByteOffset: base + i, as: UInt8.self)))
                    if v != 0 && v != centerLabel { return .multiLabel }
                }
            case .uint8:
                for i in 0..<elemCount {
                    let v = Int(rawBuf.loadUnaligned(fromByteOffset: base + i, as: UInt8.self))
                    if v != 0 && v != centerLabel { return .multiLabel }
                }
            case .int16:
                for i in 0..<elemCount {
                    let raw = rawBuf.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self)
                    let v = Int(Int16(bitPattern: le ? raw : raw.byteSwapped))
                    if v != 0 && v != centerLabel { return .multiLabel }
                }
            case .uint16:
                for i in 0..<elemCount {
                    let raw = rawBuf.loadUnaligned(fromByteOffset: base + i * 2, as: UInt16.self)
                    let v = Int(le ? raw : raw.byteSwapped)
                    if v != 0 && v != centerLabel { return .multiLabel }
                }
            case .int32, .uint32:
                // Label values are small; Int32 signed compare is exact.
                for i in 0..<elemCount {
                    let raw = rawBuf.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                    let v = Int(Int32(bitPattern: le ? raw : raw.byteSwapped))
                    if v != 0 && v != centerLabel { return .multiLabel }
                }
            case .float32:
                for i in 0..<elemCount {
                    let raw = rawBuf.loadUnaligned(fromByteOffset: base + i * 4, as: UInt32.self)
                    let fv = Float(bitPattern: le ? raw : raw.byteSwapped)
                    guard fv.isFinite else { continue }
                    let r = Int(fv.rounded())
                    guard abs(fv - Float(r)) <= 1e-3 else { return .intensity }
                    if r != 0 && r != centerLabel { return .multiLabel }
                }
            case .float64:
                for i in 0..<elemCount {
                    let raw = rawBuf.loadUnaligned(fromByteOffset: base + i * 8, as: UInt64.self)
                    let dv = Double(bitPattern: le ? raw : raw.byteSwapped)
                    guard dv.isFinite else { continue }
                    let r = Int(dv.rounded())
                    guard abs(dv - Double(r)) <= 1e-3 else { return .intensity }
                    if r != 0 && r != centerLabel { return .multiLabel }
                }
            case .rgb24, .rgba32:
                return confirmBinaryMaskPerVoxel(centerLabel: centerLabel)
            }
            return .binary
        }
    }

    private func confirmBinaryMaskPerVoxel(centerLabel: Int) -> BinaryCheckResult {
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let fv = voxel(x: x, y: y, z: z, t: 0)
                    guard fv.isFinite else { continue }
                    let r = Int(fv.rounded())
                    guard abs(fv - Float(r)) <= 1e-3 else { return .intensity }
                    if r != 0 && r != centerLabel { return .multiLabel }
                }
            }
        }
        return .binary
    }

    private func rawVoxelValue(byteOffset: Int) -> Float {
        let bytesNeeded = image.header.datatype.bytesPerVoxel
        guard byteOffset >= 0, byteOffset + bytesNeeded <= image.payloadCount else {
            return 0
        }
        let le = image.header.littleEndian
        switch image.header.datatype {
        case .uint8:
            return Float(image.byte(atPayloadOffset: byteOffset))
        case .int8:
            return Float(Int8(bitPattern: image.byte(atPayloadOffset: byteOffset)))
        case .int16:
            return Float(Int16(bitPattern: MIQBinaryReader.uint16(image.storage, image.payloadOffset + byteOffset, littleEndian: le)))
        case .uint16:
            return Float(MIQBinaryReader.uint16(image.storage, image.payloadOffset + byteOffset, littleEndian: le))
        case .int32:
            return Float(Int32(bitPattern: MIQBinaryReader.uint32(image.storage, image.payloadOffset + byteOffset, littleEndian: le)))
        case .uint32:
            return Float(MIQBinaryReader.uint32(image.storage, image.payloadOffset + byteOffset, littleEndian: le))
        case .float32:
            return Float(bitPattern: MIQBinaryReader.uint32(image.storage, image.payloadOffset + byteOffset, littleEndian: le))
        case .float64:
            return Float(Double(bitPattern: MIQBinaryReader.uint64(image.storage, image.payloadOffset + byteOffset, littleEndian: le)))
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
    ///
    /// Called once per voxel in the hot decode loop, so it must not allocate: the
    /// previous `var c = [0, 0, 0]` heap array is replaced with three stack
    /// locals placed by axis. Output is identical — `sliceAxis`/`hAxis`/`vAxis`
    /// are a permutation of {0,1,2}, so exactly one assignment lands in each of
    /// x/y/z, exactly as the array form did.
    func coordinate(slice: Int, row: Int, col: Int) -> (x: Int, y: Int, z: Int) {
        let hVal = hReversed ? (hDim - 1 - col) : col
        let vVal = vReversed ? (vDim - 1 - row) : row
        var x = 0, y = 0, z = 0
        switch sliceAxis { case 0: x = slice; case 1: y = slice; default: z = slice }
        switch hAxis { case 0: x = hVal; case 1: y = hVal; default: z = hVal }
        switch vAxis { case 0: x = vVal; case 1: y = vVal; default: z = vVal }
        return (x, y, z)
    }
}
