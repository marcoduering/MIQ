import Foundation

public enum MIQFileKind: Sendable, CaseIterable {
    case nii
    case niiGz
    case mgh
    case mgz
    case mif
    case mifGz

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
        default: return nil
        }
    }

    public var isCompressed: Bool {
        switch self {
        case .niiGz, .mgz, .mifGz: return true
        case .nii, .mgh, .mif: return false
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
        }
    }

    public static var allDisplaySuffixes: [String] {
        [".nii", ".nii.gz", ".mgh", ".mgz", ".mgh.gz", ".mif", ".mif.gz"]
    }
}
