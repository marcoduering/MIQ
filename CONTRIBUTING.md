# Contributing to MIQ

Thank you for your interest in contributing!

## Project Structure

- `Sources/MIQCore` — pure Swift package, no AppKit/UIKit; consumed by SPM and the extension target
- `MIQQuickLookExtension` — the Quick Look extension target: preview controller, views, slice cache
- `MIQApp` — SwiftUI host app that installs the extension and provides the Settings UI (image orientation, intensity windowing, axis labels, metadata panel configuration)
- `Tests/MIQCoreTests` — Swift Testing coverage for `MIQCore`

## Building from Source

### Prerequisites

- macOS 14 or later
- Xcode 16 or later
- An Apple Developer account (free or paid) for code signing

### First-time Setup

Signing credentials are kept out of the repository via a gitignored xcconfig file.

1. Copy the template:
   ```bash
   cp LocalSigning.xcconfig.template LocalSigning.xcconfig
   ```
2. Open `LocalSigning.xcconfig` and fill in your values:
   - `APP_BUNDLE_ID` → a reverse-DNS identifier you own, e.g. `com.yourname.miq`
   - `EXTENSION_BUNDLE_ID` → same prefix with `.extension`, e.g. `com.yourname.miq.extension`
   - `DEVELOPMENT_TEAM` → leave empty for Debug builds; Xcode infers the team from your signed-in Apple ID automatically
   - `APP_GROUP_ID` → already set to `group.$(APP_BUNDLE_ID)` in the template; change only if your App Group is named differently

`LocalSigning.xcconfig` is gitignored and will never appear in commits or pull requests.

### App Group and Settings

The app and the Quick Look extension share settings through an App Group (`group.<your-bundle-id>`). With Automatic signing (the default for Debug builds), Xcode registers the App Group in the Apple Developer Portal automatically the first time you build.

If the App Group is not provisioned — for example, before the first successful Automatic-signing build — the extension still renders correctly but will probably ignore any settings changed in the app and use built-in defaults for everything instead. Or you will get an OS-level error message about external access.

### Build and Run

```bash
# Install extension and refresh Quick Look services (recommended during development)
./scripts/build.sh

# Or build directly with xcodebuild
xcodebuild -project MIQ.xcodeproj -scheme MIQ -configuration Debug \
  -destination 'generic/platform=macOS' build
```

Then open a supported file in Finder and press **Space**.

### Run Tests

```bash
swift test --package-path .
```

## Performance Notes

These design decisions affect the render path — keep them in mind when working on parsing or preview code:

- Uncompressed files (`.nii`, `.mgh`, `.mif`) are memory-mapped; the payload is never copied.
- Slice extraction computes only the requested planes — no full volume resampling.
- Each slice is downsampled to a maximum of 512 px on the long side before display.
- Parsers are implemented from scratch in Swift, without third-party dependencies or bindings to C/C++ libraries.

> Please note that Debug builds are not optimized for performance and are much slower. Test performance only with Release builds.

## Submitting Changes

- Open an issue first for anything beyond small bug fixes.
- Keep pull requests focused — one concern per PR.
- Run `swift test` before submitting.
- Use `MIQ`-prefixed names for product-level types, concise domain names for generic imaging concepts (`GrayscaleImage`, `SlicePlane`), and descriptive names for internal helpers.

## Releasing (maintainers only)

Notarized release builds require a Developer ID Application certificate (paid Apple Developer Program membership) and the `scripts/release_notarize.sh` script.
