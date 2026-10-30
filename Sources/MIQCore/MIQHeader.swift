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
    /// Optional override for the displayed format name. When `nil`, callers should fall back to
    /// `MIQFileKind.displayName`. Set by parsers that detect compression at parse time (e.g. NRRD,
    /// where `.nrrd` covers both raw and gzipped payloads), and by NIfTI-2, which shares its file
    /// kinds with NIfTI-1.
    public let formatLabel: String?
    /// Optional override for the displayed datatype name. When `nil`, callers fall back to
    /// `datatype.label`. Set by parsers whose on-disk datatype has no `MIQDatatype` equivalent and
    /// is normalised at parse time (MIF `bit`, expanded to one `uint8` per voxel) so the metadata
    /// panel still reports what the file actually says.
    public let datatypeLabel: String?
    /// Authoritative anatomical orientation, when derivable from the file's header.
    /// Populated at parse time by each format-specific parser. `nil` means orientation
    /// is genuinely unknown (no usable sform, qform, MIF layout, or MGH direction cosines).
    /// Consumed by `OrientationResolver` as the single source of truth for display labels and slice planning.
    public let orientationFrame: OrientationFrame?
    /// Free-text description from the header (NIfTI `descrip`, MIF `comments:`, NRRD
    /// `content:`, MetaImage `Comment`), already cleaned by `MIQParser.headerComment`;
    /// lines are separated by "\n". `nil` when the format has none or it is empty.
    /// Can name a patient (MRtrix copies DICOM patient fields into `comments:`), so
    /// never log it publicly.
    public let comment: String?
    /// How MIQ's x, y, z, t axes map to the file's own axes, for the voxel-index
    /// readout. `nil` when they already are the file's axes 0–3 in order.
    public let fileIndexAxes: FileIndexAxes?

    public var width: Int { dimensions[safe: 0] ?? 1 }
    public var height: Int { dimensions[safe: 1] ?? 1 }
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
        srowZ: [Float],
        formatLabel: String? = nil,
        datatypeLabel: String? = nil,
        orientationFrame: OrientationFrame? = nil,
        comment: String? = nil,
        fileIndexAxes: FileIndexAxes? = nil
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
        self.formatLabel = formatLabel
        self.datatypeLabel = datatypeLabel
        self.orientationFrame = orientationFrame
        self.comment = comment
        self.fileIndexAxes = fileIndexAxes
    }

    /// The voxel at MIQ's (x, y, z, t) as the file indexes it, counted from 0:
    /// three values for a 3D image, four for 4D, in the file's axis order. This is
    /// what the file's own tools report (mrview, nibabel, ITK), independent of the
    /// view orientation.
    public func fileVoxelIndex(x: Int, y: Int, z: Int, t: Int) -> [Int] {
        let cursor = [x, y, z, t]
        let count = volumes > 1 ? 4 : 3
        guard let axes = fileIndexAxes else { return Array(cursor.prefix(count)) }
        var index = [Int](repeating: 0, count: count)
        for axis in 0..<count {
            let value = cursor[axis]
            index[axes.fileAxis[axis]] = axes.reversed[axis] ? (dimensions[axis] - 1 - value) : value
        }
        return index
    }
}

/// MIQ's x, y, z, t axes in the file's terms. MIF stores its spatial axes in
/// layout order and MIQ reads reversed ones forwards; NRRD may put its volume axis
/// first. Both formats address voxels along the file's own axes.
public struct FileIndexAxes: Sendable, Equatable {
    /// The file axis each of MIQ's x, y, z, t is.
    public let fileAxis: [Int]
    /// Whether MIQ walks that axis against the file's index direction.
    public let reversed: [Bool]

    public init(fileAxis: [Int], reversed: [Bool]) {
        self.fileAxis = fileAxis
        self.reversed = reversed
    }

    /// MIQ's axes already are the file's, in order and direction.
    public var isIdentity: Bool {
        fileAxis == [0, 1, 2, 3] && !reversed.contains(true)
    }
}

/// Voxel spacing used for rendering: `abs(value)` when it is finite and positive, else 1.
/// A zero spacing is common in hand-written headers and every mainstream viewer reads it as
/// 1 (a tiny floor instead squashed that axis to a single pixel); a non-finite one would
/// poison the physical-extent arithmetic. Applied at render time, so `pixdim` keeps the
/// header's raw values for the metadata panel; MGH is the exception, having always stored
/// its clamped voxel sizes.
func sanitizedSpacing(_ value: Float) -> Float {
    let magnitude = abs(value)
    return magnitude.isFinite && magnitude > 0 ? magnitude : 1
}
