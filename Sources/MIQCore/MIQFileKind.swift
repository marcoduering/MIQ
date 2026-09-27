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

    /// Whether the Finder thumbnail extension should decline this file (keeping
    /// the system icon) rather than parse it. A thumbnail is spawned per visible
    /// icon, so a folder of large 4D `.mif.gz`/`.mgz` would otherwise fully
    /// decompress one file per icon. Declines only when rendering the centre
    /// slice would pull the whole file: a non-boundable kind over `thresholdBytes`
    /// that is compressed, is `.nrrd` (the header, not the extension, decides
    /// whether its payload is gzip), or sits on a network volume. Local
    /// uncompressed MGH/MIF are memory-mapped, so size costs them nothing. An
    /// unknown size (`nil`) never declines.
    public func declinesThumbnail(fileSizeBytes: Int?, isLocal: Bool, thresholdBytes: Int) -> Bool {
        guard !supportsBoundedNetworkRead,
              let fileSizeBytes, fileSizeBytes > thresholdBytes else { return false }
        return isCompressed || self == .nrrd || !isLocal
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
