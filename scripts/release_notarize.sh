#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   TEAM_ID="YOUR_TEAM_ID" NOTARY_PROFILE="my-notary-profile" ./scripts/release_notarize.sh
#
# Required setup:
# - Xcode command line tools installed
# - Developer ID Application certificate in keychain
# - notarytool credentials profile, for example:
#   xcrun notarytool store-credentials "my-notary-profile" \
#     --apple-id "APPLE_ID_EMAIL" \
#     --team-id "YOUR_TEAM_ID" \
#     --password "app-specific-password"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="MIQ.xcodeproj"
SCHEME="MIQ"
CONFIGURATION="Release"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "ERROR: NOTARY_PROFILE is required."
  echo "Example: NOTARY_PROFILE=my-notary-profile $0"
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not found."
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "ERROR: xcrun not found."
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "ERROR: No 'Developer ID Application' certificate found in keychain."
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT_DIR/build/release-$TIMESTAMP"
ARCHIVE_PATH="$OUT_DIR/MIQ.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
ZIP_PATH="$OUT_DIR/MIQ.zip"
EXPORT_PLIST="$OUT_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/MIQ.app"

mkdir -p "$OUT_DIR"

if [[ -n "$TEAM_ID" ]]; then
  cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
</dict>
</plist>
EOF
else
  cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
EOF
fi

echo "==> Archiving"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  archive \
  -archivePath "$ARCHIVE_PATH"

echo "==> Exporting signed app (Developer ID)"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: Exported app not found at $APP_PATH"
  exit 1
fi

echo "==> Packaging app for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting for notarization"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Validating stapled ticket"
xcrun stapler validate "$APP_PATH"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "==> Code signature verification"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo

echo "SUCCESS"
echo "Notarized app: $APP_PATH"
echo "Build folder:   $OUT_DIR"
