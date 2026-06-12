import Foundation

/// Label-colouring mode for integer segmentation volumes.
/// `.off` always uses percentile windowing (default, legacy behaviour).
/// `.auto` detects label volumes and colours them: canonical FreeSurfer colours
/// when the labels look like a FreeSurfer parcellation, otherwise deterministic
/// random colours per label.
/// `.random` forces the random palette and never consults the FreeSurfer table.
/// Detection only fires for integer/identity-scaled data with few distinct values,
/// so intensity images are unaffected.
public enum SegmentationColoring: String, Sendable, CaseIterable {
    case off = "off"
    case auto = "auto"
    case random = "random"
}
