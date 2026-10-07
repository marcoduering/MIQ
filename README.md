# MIQ: Medical Image Quick Look

MIQ is a lightweight **macOS QuickLook extension** for medical volume images. Press **Space** on a supported file in Finder to instantly get an **interactive orthogonal slice view** alongside a metadata panel. A Windows counterpart, [**MIQ-Win**](https://github.com/marcoduering/MIQ-Win), is also available.

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_Bento_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_Bento.webp" width="90%" alt="Bento-style feature grid for MIQ: press Space in Finder for an interactive Quick Look preview; supports NIfTI, FreeSurfer, MRtrix and NRRD formats; the center tile shows a brain MRI in a coronal/sagittal/axial 2x2 grid with a metadata panel listing format NIfTI-1, dimensions 211 x 215 x 175, spacing 1.00 mm isotropic, orientation RAS, datatype int16 and 1 volume; other tiles show FreeSurfer LUT segmentation coloring, color label files, Finder thumbnails, 4D file support, full configurability, and availability on macOS and Windows.">
  </picture>
</div>

**See it in action** in the short video at the bottom of this page.

## Main Features and Supported Formats

- **Instant, interactive preview** — press Space for the 2×2 orthogonal slice and metadata view
- **Built for speed** — memory-mapping, partial decompression, and network volumes read only what's needed for the first preview
- **4D support** — scrub through timepoints/volumes interactively
- **Segmentation coloring** — including automatic label-color detection for FreeSurfer-style parcellations
- **Finder thumbnails** — optional file-icon slice previews while browsing
- **Fully configurable** — orientation display, intensity windowing, label colors, and metadata panel content/order, all from the main app

Supported formats:

- :white_check_mark: **NIfTI-1 & NIfTI-2** — `.nii`, `.nii.gz`
- :white_check_mark: **FreeSurfer** — `.mgh`, `.mgz`, `.mgh.gz`
- :white_check_mark: **MRtrix** — `.mif`, `.mif.gz`
- :white_check_mark: **NRRD** — `.nrrd` *(only single-file variant with attached header)*

All formats are supported uncompressed and gzip-compressed.

## Installation & Updates

The app and extension can be installed manually or via the package manager [Homebrew](https://brew.sh).

> The app is a universal binary for Apple Silicon (arm64) and Intel (x86_64) Macs and has been tested on macOS 14 (Sonoma), 15 (Sequoia), 26 (Tahoe) and 27 (Golden Gate).

### Manual installation

1. 👉 **[Download the latest release (MIQ.app.zip)](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip)**
[![Latest Release](https://img.shields.io/github/v/release/marcoduering/MIQ)](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip)
2. Unzip and move **`MIQ.app`** to your **`/Applications`** folder.
3. **Open `MIQ.app`** at least once to register the Quick Look extension.
4. Press **Space** on any supported file in Finder.
5. Optional: **Customize the preview** in the MIQ app.

#### Updating

MIQ updates itself. Open the MIQ app and choose MIQ → Check for Updates…, or leave **Check for updates automatically** enabled in the app's **General** pane (on by default).

Automatic checks and updates happen when you open the main app, so make sure to do this from time to time.

### Installation via Homebrew

1. Install on the command line:

   ```bash
   brew tap marcoduering/miq
   brew trust --cask marcoduering/miq/miq
   brew install --cask miq
   ```

2. **Open `MIQ.app`** (in `/Applications`) at least once to register the Quick Look extension.
3. Press **Space** on any supported file in Finder.
4. Optional: **Customize the preview** in the MIQ app.

#### Updating via Homebrew

The cask is marked `auto_updates`, so the app updates itself (see above). To update through Homebrew instead:

```bash
brew update
brew upgrade --cask miq --greedy
```

## Usage

MIQ is a lightweight convenience tool for quickly inspecting medical image files directly from the Finder. It prioritizes speed and ease of use over advanced visualization, and is not meant to replace dedicated medical image viewers.

### Customization

Use the MIQ app to tailor the preview, metadata panel and thumbnails. Live examples show the effect of each setting as you change it. The **Controls** pane lists all gestures for the interactive preview.

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings1_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings1.webp" width="32%" alt="MIQ settings, Preview pane: orientation, segmentation colours, axis label and crosshair colour, and intensity window controls beside a live example of the rendered preview.">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings2_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings2.webp" width="32%" alt="MIQ settings, Metadata pane: a reorderable list of metadata fields, each with an on/off toggle, beside a live example of the metadata panel.">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings3_dark.webp">
    <img src="https://raw.githubusercontent.com/marcoduering/MIQ/main/docs/MIQ_settings3.webp" width="32%" alt="MIQ settings, Thumbnails pane: a toggle for Finder slice thumbnails with orientation, segmentation colour and intensity window controls, beside a live example of the Finder icons.">
  </picture>
</div>

### Orientation

By default, MIQ displays data **as stored on disk**, without reorienting. Images may appear upside down, mirrored, or rotated depending on acquisition. This is by design, so you can inspect the raw data "as is". Optional settings reorient to **Neurological** or **Radiological view**.

## Troubleshooting

### `.gz` File Handling

macOS Quick Look routes files to extensions by file name suffix. Several kinds of tools, including archive utilities, source-code viewers, and format-specific extensions like MIQ, need to claim the broad `.gz` suffix to support compound extensions such as `.nii.gz`/`.mif.gz`. When more than one installed extension claims `.gz`, which one macOS shows isn't always consistent; this is general Quick Look behavior, not specific to MIQ. If a gzip-compressed file isn't opening with MIQ's preview, try deactivating other `.gz`-handling extensions.

## Active Development

MIQ is free and open source, in active development, and was created with the support of AI coding agents. Report issues or feature suggestions via [**GitHub Issues**](https://github.com/marcoduering/MIQ/issues), or see [CONTRIBUTING.md](./CONTRIBUTING.md) to contribute. If MIQ is useful to you, consider [**sponsoring the project**](https://github.com/sponsors/marcoduering) (entirely optional, always appreciated).

## Disclaimer & License

MIQ is provided "as is" under [MIT License](./LICENSE), without warranty of any kind, express or implied. The authors and contributors accept no liability whatsoever for any direct, indirect, incidental, special, or consequential damages arising from the use or inability to use this software, including but not limited to data loss, incorrect image rendering, or any decisions made on the basis of previews generated by this tool.

> [!CAUTION]
> This software is **<ins>not</ins> a medical device and is <ins>not</ins> intended for diagnostic use**. It is a developer and researcher convenience tool only. Do not use it to make clinical decisions.

## See it in action

<div align="center">
  <video src="https://github.com/user-attachments/assets/3058f94e-4ffa-4c0a-a1b8-d1578de0f651" width="600"></video>
</div>
