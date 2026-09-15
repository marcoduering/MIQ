import Foundation

/// One symbolic MIF layout entry.
/// `order` is the storage rank (0 = fastest-varying axis), `reversed` is traversal direction.
struct MIFLayoutComponent {
    let order: Int
    let reversed: Bool

    init(order: Int, reversed: Bool) {
        self.order = order
        self.reversed = reversed
    }

    init(signedOrder: Int) {
        self.order = abs(signedOrder)
        self.reversed = signedOrder < 0
    }
}

/// Encapsulates axis stride and orientation computation for MRtrix MIF/MIF.GZ files.
/// The MIF `layout` field assigns each axis a signed rank: abs(rank) gives storage order
/// (0 = fastest-varying), sign gives traversal direction (+= forward, -= reversed).
struct MIFAxisLayout {
    /// Signed element strides per axis in file storage order.
    /// Negative strides indicate a reversed axis; use `baseElementIndex` as the starting element.
    let rawStrides: [Int]
    /// Element index of voxel [0,0,...,0] when any stride is negative.
    let baseElementIndex: Int

    init(dim: [Int], layout: [MIFLayoutComponent]) throws {
        let axisCount = layout.count
        guard axisCount == dim.count, axisCount >= 3 else {
            throw MIQError.invalidDimensions
        }
        guard Set(layout.map { $0.order }).count == axisCount else {
            throw MIQError.malformedFile("MIF layout contains duplicate axis orders")
        }

        let sortedAxes = (0..<axisCount).sorted { layout[$0].order < layout[$1].order }
        var strides = Array(repeating: 0, count: axisCount)
        var stride = 1
        for axis in sortedAxes {
            let sign = layout[axis].reversed ? -1 : 1
            strides[axis] = sign * stride
            stride *= dim[axis]
        }

        var base = 0
        for axis in 0..<axisCount where strides[axis] < 0 {
            base += (dim[axis] - 1) * abs(strides[axis])
        }

        self.rawStrides = strides
        self.baseElementIndex = base
    }

    init(dim: [Int], layout: [Int]) throws {
        try self.init(dim: dim, layout: layout.map { MIFLayoutComponent(signedOrder: $0) })
    }

    /// Composes the `transform:`-derived image-axis frame with the `layout:` field to give the
    /// volume's actual anatomical orientation — the one a NIfTI export bakes into its affine.
    ///
    /// MRtrix realigns on import and writes back a canonical transform, so the transform alone
    /// is RAS for essentially every MRtrix-written file and the orientation really lives in the
    /// layout. Composing the two is also realignment-invariant: a canonical transform stored
    /// reversed and an LAS transform stored forward both land on LAS, as they must, since both
    /// put element order on the same R→L run. See the MIF orientation convention in CLAUDE.md.
    ///
    /// `spatialAxes` is the 3 spatial axis indices sorted by abs(layout) — fastest to slowest.
    /// Distinctness is preserved: reversing an axis changes its direction, never its world axis.
    static func storageFrame(
        imageFrame: OrientationFrame,
        spatialAxes: [Int],
        layout: [MIFLayoutComponent]
    ) -> OrientationFrame {
        let axes = spatialAxes.map { axis -> StorageAxisOrientation in
            let anatomy = imageFrame.axes[axis]
            return layout[axis].reversed ? anatomy.opposite : anatomy
        }
        return OrientationFrame(axes: axes, source: .mifLayout)
    }
}
