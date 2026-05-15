# MIQ — Medical Image Quick Look

MIQ is a lightweight **macOS QuickLook preview extension** for medical volume images stored in common research formats. Press **Space** on a supported file in Finder to instantly see an orthogonal slice view alongside a metadata panel:

<div align="center">
  <img src="https://github.com/marcoduering/MIQ/releases/download/readme-assets/MIQ_screenshot.webp" width="65%">
</div>

Inspired by the old, deprecated [DTI-TK Quick Look **plugin**](http://dti-tk.sourceforge.net/pmwiki/pmwiki.php) by Gary Hui Zhang, which offered similar functionality on older macOS versions but is incompatible with current macOS Quick Look **extension** architecture.

## Supported Formats

- :white_check_mark: **NIfTI-1 & NIfTI-2** — `.nii`, `.nii.gz`
- :white_check_mark: **FreeSurfer** — `.mgh`, `.mgz`, `.mgh.gz`
- :white_check_mark: **MRtrix** — `.mif`, `.mif.gz`
- :eight_spoked_asterisk: **NRRD** — `.nrrd` *(experimental, and only the single file variant with attached header)*

All formats are supported uncompressed and gzip-compressed. The extension relies on the file extension to determine the format, so it is **important that files have the correct extensions**.

## Installation & Updates

The app and extension can be installed manually or via the package manager [Homebrew](https://brew.sh). 

> The app is universal for Apple Silicon (arm64) and Intel (x86_64) Macs and has been tested on Apple Silicon with macOS 14 (Sonoma), 15 (Sequoia), and 26 (Tahoe).

### Manual installation

1. 👉 **[Download the latest release (MIQ.app.zip)](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip)**
[![Latest Release](https://img.shields.io/github/v/release/marcoduering/MIQ)](https://github.com/marcoduering/MIQ/releases/latest/download/MIQ.app.zip)
2. Unzip and move **`MIQ.app`** to your **`/Applications`** folder.
3. **Open `MIQ.app`** at least once to register the Quick Look preview extension.
4. Press **Space** on any supported file in Finder.
5. Optional: **Configure the preview settings** in the MIQ app.

<div align="center">
  <img src="https://github.com/marcoduering/MIQ/releases/download/readme-assets/MIQ_settings1.webp" width="49%">
  <img src="https://github.com/marcoduering/MIQ/releases/download/readme-assets/MIQ_settings2.webp" width="49%">
</div>

### Manual update

The MIQ main app has an update checker, which will alert you in case a new version is available. Make sure to open the main app from time to time to check for updates.

### Installation via Homebrew

1. Install on the command line:

```bash
brew tap marcoduering/miq
brew install --cask miq
```
2. **Open `MIQ.app`** (in `/Applications`) at least once to register the Quick Look preview extension.
3. Press **Space** on any supported file in Finder.
4. Optional: Configure the preview settings in the MIQ app.

#### Updating via Homebrew

```bash
brew upgrade --cask miq
```

## Usage

MIQ is a lightweight convenience tool for quickly inspecting medical image files directly from the Finder. It prioritizes speed and ease of use over advanced visualization, and is not meant to replace dedicated medical image viewers.

### Orientation

By default, MIQ displays data **as stored on disk**, without reorienting. Depending on acquisition and processing, images may appear upside down, mirrored, or rotated. This is intentional, so you can quickly inspect the raw data including its orientation. If desired, there are settings to reorient to **Neurological view** or **Radiological view**. In both reoriented conventions, sagittal displays patient anterior on the viewer's left. Please note that for multi-volume (4D) data, only the first volume is shown.

### Interactive Mode

The preview is initially static (showing center slices) for maximum speed. However, there is an **interactive mode** that allows you to navigate through the slices. Activate it by clicking on an image slice, a cross-hair will appear. You can click, drag and scroll to navigate the volume.

### Customization

Use the settings (main app) to tailor the preview to your needs. You can adjust the render orientation (see above), intensity scaling, label colors and the metadata panel (content and order of the items).

### Performance

Static previews are designed to appear almost instantly. Uncompressed files (`.nii`, `.mgh`, `.mif`) are memory-mapped and impose essentially no load time regardless of size. Compressed files (`.nii.gz`, `.mgz`, `.mif.gz`) require decompression before rendering and very large compressed volumes may take a few seconds to load.

## Troubleshooting

### Conflicts with Other Quick Look Extensions

macOS assigns Quick Look extensions to file types based on their extensions. Since `.gz` is a generic extension shared by many file types, MIQ must claim it broadly to handle `.nii.gz` and `.mif.gz` files. This can interfere with other Quick Look extensions that also manage `.gz` files (for example, extensions for compressed archives or source code).  
The most recently installed extension should have priority, but this does not work consistently. You might need to deactivate another extension to reliably open gzip-compressed files with MIQ. This is a known limitation of how macOS Quick Look handles compound extensions like `.nii.gz`.

## Active Development

The extension is still in development. It was created with the support of AI coding agents. Please report any issues or feature suggestions using [**GitHub Issues**](https://github.com/marcoduering/MIQ/issues). If you would like to contribute, see [CONTRIBUTING.md](./CONTRIBUTING.md) or feel free to reach out.

## Disclaimer & License

MIQ is provided "as is" under [MIT License](./LICENSE), without warranty of any kind, express or implied. The authors and contributors accept no liability whatsoever for any direct, indirect, incidental, special, or consequential damages arising from the use or inability to use this software, including but not limited to data loss, incorrect image rendering, or any decisions made on the basis of previews generated by this tool.

> [!CAUTION]
> This software is **<ins>not</ins> a medical device and is <ins>not</ins> intended for diagnostic use**. It is a developer and researcher convenience tool only. Do not use it to make clinical decisions.
