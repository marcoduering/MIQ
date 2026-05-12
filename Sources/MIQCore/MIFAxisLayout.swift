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

    /// Derives a 3-letter anatomical orientation label (e.g. "RAS") from a MIF layout field.
    /// `spatialAxes` is the 3 spatial axis indices sorted by abs(layout) — fastest to slowest.
    /// MRtrix convention: axis 0 = L(−)/R(+), axis 1 = P(−)/A(+), axis 2 = I(−)/S(+).
    static func orientationLabel(spatialAxes: [Int], layout: [MIFLayoutComponent]) -> String {
        let positive = ["R", "A", "S"]
        let negative = ["L", "P", "I"]
        return spatialAxes.map { axis in
            layout[axis].reversed ? negative[axis] : positive[axis]
        }.joined()
    }
}
