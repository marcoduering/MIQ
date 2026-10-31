# MIQ Architecture

The goal is a lightweight, fast Quick Look plugin. Every rule below serves time to first frame, low memory, and never stalling Finder.

Multi-file formats are out of scope, not just unimplemented: the sandboxed extension cannot open a sibling of the previewed file. So detached `.nhdr`/`.mhd`, Analyze `.hdr`/`.img` and DICOM series are not possible.

## Targets

| Target | Role |
|---|---|
| `Sources/MIQCore` | Swift package, Foundation + system zlib only. Parsing, slicing, windowing, orientation, segmentation LUTs, settings (`MIQConfig`). Tested by `Tests/MIQCoreTests`. |
| `MIQQuickLookExtension` | View-based `QLPreviewingController`: controller, `MIQPreviewModel` (MainActor state), AppKit views, preview cache, `NetworkReadLane`. |
| `MIQThumbnailExtension` | `QLThumbnailProvider`: axial centre slice of volume 0, nothing interactive. |
| `MIQApp` | SwiftUI settings app, registers the extensions, hosts Sparkle. |

Shared by file membership, not a module: `MIQImageBridge.swift` (all three app targets), `MIQLogger.swift` (both extensions), `MetadataPanelText.swift` (preview extension and app).

## Preview pipeline

1. `preparePreviewOfFile` checks `MIQFileKind`, returns at once, and starts `MIQPreviewModel.load()`.
2. Off the MainActor: cache key (path, mtime, settings), locality (`statfs`), network size gate.
3. Cache hit: show the cached frame. Large network file: show the "Load Preview" placeholder. Otherwise: cold read.
4. Cold read: `MIQParser.parse` → `MIQImage` (storage, payload offset, optional element strides) → `MIQVolume.centerPreview` (three centre slices, window, LUT) → `RGBABitmap`. Local files run in a detached task; network files go through `NetworkReadLane`.
5. MainActor: wrap bitmaps in `NSImage`, nothing else.
6. Interaction re-renders only the planes whose slice index changed, in a detached task. Stepping past volume 0 of a volume-0-capped file triggers one full re-parse (`fullyDecompress: true`).

## Rules

**Performance**
- Local files are memory-mapped with `.alwaysMapped` (not `.mappedIfSafe`, which reads external drives in full). Network files are never mapped.
- Decompress only what the cold preview reads: `.nii.gz` stops after volume 0. `.mgz` and `.mif.gz` must decompress in full (MIF strides can scatter one volume across the file).
- Network reads are chunked, cancelable and I/O-throttled (`IOPOL_THROTTLE`), one at a time, newest request first. A preview on screen never loses its file; only reads no preview wants are dropped. Throttling is per thread, so a throttled read must contain no `await`.
- Read-ahead (`F_RDADVISE`) is for the preview's local reads only. Keep the compressed read-ahead lead small; `ReadAheadTests` pin the ranges.
- The thumbnail extension never reads ahead and declines files over the thumbnail size limit whose centre slice would need a full read or decompression.
- The MainActor does no parsing or pixel work, and detached tasks create no `NSImage` (it is not `Sendable`).
- Closed decisions: no alternative decompressor (system zlib is as fast and keeps capped, cancelable inflate), and no disk-backed preview cache (rendered slices are patient data).
- Measure parsing, slicing, windowing or decompression changes with `PerformanceBaselineTests` (`MIQ_PERF=1`, release build).

**Correctness**
- Malformed files must throw, never trap. Header-supplied numbers use overflow-safe arithmetic (`addingReportingOverflow`, subtraction-form bounds checks).
- The gzip trailer's ISIZE is an allocation hint, never a bound: it wraps at 4 GiB.
- Payloads are read in place via offsets and strides, never copied. The one exception is MIF `bit`, expanded to `uint8` at parse time. Axis reversal only changes orientation labels, never voxel addressing.
- The slice decode hot path in `MIQVolume` must stay bit-identical to the public `voxel()` accessor; tests compare both.
- Orientation is derived once at parse time into `OrientationFrame`. When it is `nil`, labels show "?"; anatomy is never inferred from axis indices.
- MIF orientation is the `transform:` frame composed with the `layout:` signs (`MIFAxisLayout.storageFrame`), not the transform alone: MRtrix rewrites the transform canonically, so the orientation lives in the layout. The reference is the axcode of `mrconvert x.mif x.nii.gz`.
- Label maps are detected by integrality plus piecewise constancy (`maxEdgeRatio`). The label count is not a signal (`maxLabels` is only a resource guard), the early exit may only reject, and too small a sample abstains. FreeSurfer colours come from `FreeSurferColorLUT.txt`, never invented.
- The intensity window's 1e-6 floor stays absolute; scaling it by the maximum lets one outlier voxel hide the tissue.

**Preview extension**
- Every repaint is gated on `self.model === model`: Quick Look reuses a controller, and a superseded parse still completes.
- Bind `self` strongly after an `await` in model and controller tasks; a `guard let self` before it keeps old controllers and their reads alive.
- `NetworkReadLane` must not classify previews by host (`window.level` is 0 at `prepare` for both). Keep its `[lane]` log lines.
- The full-screen event rescue paths (`handleOrphanedEvent`, `handleOrphanedScroll`) are required: full-screen Quick Look delivers most events with no window.
- Any input-handling change updates the Controls pane in `ContentView`.
- `nonisolated(unsafe)` on `MIQPreviewCache.cache` and the QL completion handler is deliberate.
- Log through `MIQLogger.make(category:)`. File names are `.private(mask: .hash)`, error messages `.private` with the public `logCode` next to them, header comments never public.

**Preview cache**
- `MIQPreviewCache.makeKey` must include every setting that changes cold-preview pixels. Today: path, mtime, max dimension, both percentiles, orientation, segmentation colouring. `perVolumeIntensityWindow` is excluded because it only affects volumes after 0. Layout-only settings stay out of `RenderingOptions`.

**Adding a format** (`MIQParser+MetaImage.swift` is the latest example)
1. `MIQFileKind` case and its switches.
2. `MIQParser+<Format>.swift`.
3. The UTI in `MIQApp/Info.plist`, `MIQQuickLookExtension/Info.plist` and `MIQThumbnailExtension/Info.plist`. A missing plist entry means Finder never calls the parser. The extensions' extra UTIs (`gov.nih.nifti-1`, the gzip types) are required for routing. `.mgz` conforms to `public.data` only, so Archive Utility isn't offered.
4. The user-facing format lists: General pane chips, the network and thumbnail (i) texts, `MIQError.unsupportedFileFormat`, README.

**Dependencies and network**
- Parsers are written from scratch; no third-party code in `MIQCore` or the extensions.
- The extensions never connect to the internet. Sparkle lives in the app only; previews show an update reminder after 30 days without a check (`UpdateReminder.intervalDays`).

**Settings and versioning**
- App and extensions share settings through the App Group named by `MIQAppGroupID` in each `Info.plist`, read via `MIQConfig`.
- A new setting gets a key in `MIQConfig.Keys`, a default in `MIQConfig.Defaults` (never inline literals; non-primitive types use a `.defaultValue` static), an `@AppStorage(..., store: Self.store)` binding and a line in `restoreDefaults()`.
- The network deferral threshold and the thumbnail size limit are separate settings; one must never change the other.
- The Settings window has one fixed size and no scrolling; explanations go in (i) popovers. Its sample images are single-slice extracts made with `scripts/dev/make_settings_sample.py`.
- macOS stores every thumbnail it is given. The Thumbnails pane, the README Privacy section and `docs/privacy.html` say so and must name the same clear command.
- The version lives in `Config/Shared.xcconfig` (`MARKETING_VERSION`); `CFBundleVersion` follows it. Release order and rules: [RELEASING.md](RELEASING.md).
