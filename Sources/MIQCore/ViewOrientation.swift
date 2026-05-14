import Foundation

/// View-time reorientation mode for slice rendering. The setting is applied at
/// the slice-extraction stage only; underlying data and headers are untouched.
///
/// - `.stored`: render along storage axes (no reorientation). Labels come from the affine.
/// - `.neurological`: reorient to RAS and apply neurological display convention —
///   patient R on viewer's right (axial/coronal); sagittal shows anterior on viewer's left.
/// - `.radiological`: reorient to LAS and apply radiological display convention —
///   patient R on viewer's left (axial/coronal); sagittal shows anterior on viewer's left.
///
/// Sagittal renders identically in both reoriented modes (no L/R component in-plane).
///
/// When the affine is undeterminable (no sform/qform, no MIF orientation override),
/// the reoriented modes fall back to `.stored` for that file.
///
/// Raw values `"ras"` / `"las"` are preserved to keep existing user preferences valid
/// across this rename.
public enum ViewOrientation: String, Sendable, Hashable, CaseIterable {
    case stored
    case neurological = "ras"
    case radiological = "las"
}
