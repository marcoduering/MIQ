# MIQ Architecture

The goal is a lightweight, fast Quick Look plugin. Every rule below serves time to first frame, low memory, and never stalling Finder.

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
- Decompress only what the cold preview reads: `.nii.gz` stops after volume 0. Other compressed kinds currently decompress in full.
- Network reads are chunked and cancelable, one at a time, newest request first. A preview on screen never loses its file; only reads no preview wants are dropped.
- The thumbnail extension never reads ahead and declines files over the thumbnail size limit whose centre slice would need a full read or decompression.
- The MainActor does no parsing or pixel work.
- Measure parsing, slicing, windowing or decompression changes with `PerformanceBaselineTests` (`MIQ_PERF=1`, release build).

**Correctness**
- Malformed files must throw, never trap. Header-supplied numbers use overflow-safe arithmetic (`addingReportingOverflow`, subtraction-form bounds checks).
- The slice decode hot path in `MIQVolume` must stay bit-identical to the public `voxel()` accessor; tests compare both.
- MIF orientation is the `transform:` frame composed with the `layout:` signs (`MIFAxisLayout.storageFrame`), not the transform alone: MRtrix rewrites the transform canonically, so the orientation lives in the layout.

**Preview cache**
- `MIQPreviewCache.makeKey` must include every setting that changes cold-preview pixels. Today: path, mtime, max dimension, both percentiles, orientation, segmentation colouring. `perVolumeIntensityWindow` is excluded because it only affects volumes after 0.

**Adding a format** (`MIQParser+MetaImage.swift` is the latest example)
1. `MIQFileKind` case and its switches.
2. `MIQParser+<Format>.swift`.
3. The UTI in `MIQApp/Info.plist`, `MIQQuickLookExtension/Info.plist` and `MIQThumbnailExtension/Info.plist`. A missing plist entry means Finder never calls the parser.

**Dependencies and network**
- Parsers are written from scratch; no third-party code in `MIQCore` or the extensions.
- The extensions never connect to the internet. Sparkle lives in the app only; previews show an update reminder after 30 days without a check (`UpdateReminder.intervalDays`).

**Settings and versioning**
- App and extensions share settings through the App Group named by `MIQAppGroupID` in each `Info.plist`, read via `MIQConfig`.
- The version lives in `Config/Shared.xcconfig` (`MARKETING_VERSION`); `CFBundleVersion` follows it. Release order and rules: [RELEASING.md](RELEASING.md).
