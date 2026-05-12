import Foundation

/// View-time reorientation mode for slice rendering. The setting is applied at
/// the slice-extraction stage only; underlying data and headers are untouched.
///
/// - `.stored`: render along storage axes (legacy behavior). Labels come from the affine.
/// - `.ras`: render in neurological convention — patient R on screen R, S on top, A on top (axial).
/// - `.las`: render in radiological convention — patient L on screen R, S on top, A on top (axial).
///
/// When the affine is undeterminable (no sform/qform, no MIF orientation override),
/// `.ras` and `.las` fall back to `.stored` for that file.
public enum ViewOrientation: String, Sendable, Hashable, CaseIterable {
    case stored
    case ras
    case las
}
