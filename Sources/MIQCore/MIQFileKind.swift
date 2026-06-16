import Foundation

public enum MIQFileKind: Sendable, CaseIterable {
    case nii
    case niiGz
    case mgh
    case mgz
    case mif
    case mifGz
    case nrrd

    public init?(url: URL) {
        let path = url.path.lowercased()

        if path.hasSuffix(".nii.gz") { self = .niiGz; return }
        if path.hasSuffix(".mgh.gz") { self = .mgz; return }
        if path.hasSuffix(".mif.gz") { self = .mifGz; return }

        switch url.pathExtension.lowercased() {
        case "nii": self = .nii
        case "mgh": self = .mgh
        case "mgz": self = .mgz
        case "mif": self = .mif
        case "nrrd": self = .nrrd
        default: return nil
        }
    }

    public var isCompressed: Bool {
        switch self {
        case .niiGz, .mgz, .mifGz: return true
        case .nii, .mgh, .mif, .nrrd: return false
        }
    }

    /// Whether a cold preview of this kind can be bounded to a volume-0 prefix on
    /// a network volume. Only canonical NIfTI qualifies (see
    /// `MIQParser.loadBoundedNiftiPrefix`); every other kind needs a full read,
    /// which is what the large-network preview gate defers.
    public var supportsBoundedNetworkRead: Bool {
        switch self {
        case .nii, .niiGz: return true
        case .mgh, .mgz, .mif, .mifGz, .nrrd: return false
        }
    }

    public var displayName: String {
        switch self {
        case .nii: return "NIfTI-1"
        case .niiGz: return "Compressed NIfTI-1"
        case .mgh: return "MGH"
        case .mgz: return "Compressed MGH"
        case .mif: return "MRtrix MIF"
        case .mifGz: return "Compressed MRtrix MIF"
        case .nrrd: return "NRRD"
        }
    }

    public var pathSuffixes: [String] {
        switch self {
        case .nii: return [".nii"]
        case .niiGz: return [".nii.gz"]
        case .mgh: return [".mgh"]
        case .mgz: return [".mgz", ".mgh.gz"]
        case .mif: return [".mif"]
        case .mifGz: return [".mif.gz"]
        case .nrrd: return [".nrrd"]
        }
    }
}
