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
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT_DIR/build/release-$TIMESTAMP"
ARCHIVE_PATH="$OUT_DIR/MIQ.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
ZIP_PATH="$OUT_DIR/MIQ.zip"
EXPORT_PLIST="$OUT_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/MIQ.app"
LOG_DIR="$OUT_DIR/logs"
ARCHIVE_LOG="$LOG_DIR/archive.log"
EXPORT_LOG="$LOG_DIR/export.log"
NOTARY_LOG="$LOG_DIR/notary.log"
STAPLE_LOG="$LOG_DIR/staple.log"
VALIDATE_LOG="$LOG_DIR/validate.log"
GATEKEEPER_LOG="$LOG_DIR/gatekeeper.log"
CODESIGN_VERIFY_LOG="$LOG_DIR/codesign-verify.log"

mkdir -p "$LOG_DIR"

print_log_excerpt() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    echo "No log file found at: $log_file"
    return
  fi

  echo "----- failure summary ($log_file) -----"
  awk '
    /The following build commands failed:/ { printing=1 }
    printing { print }
    printing && /\([0-9]+ failures\)/ { exit }
  ' "$log_file" || true

  echo "----- matching error lines -----"
  grep -nEi "error:|failed|SwiftDriver|CodeSign|codesign|notarytool|provisioning profile|certificate|ARCHIVE FAILED" "$log_file" | tail -n 40 || true

  echo "----- last 80 log lines -----"
  tail -n 80 "$log_file" || true
}

run_logged() {
  local step_name="$1"
  local log_file="$2"
  shift 2

  echo "==> $step_name"
  set +e
  "$@" 2>&1 | tee "$log_file"
  local status=${PIPESTATUS[0]}
  set -e

  if [[ $status -ne 0 ]]; then
    echo
    echo "ERROR: $step_name failed with exit code $status"
    print_log_excerpt "$log_file"
    echo "Full log: $log_file"
    exit "$status"
  fi
}

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

SIGNING_IDENTITIES="$(security find-identity -v -p codesigning || true)"
if ! grep -q "Developer ID Application" <<< "$SIGNING_IDENTITIES"; then
  echo "ERROR: No 'Developer ID Application' certificate found in keychain."
  echo "Available signing identities:"
  echo "$SIGNING_IDENTITIES"
  exit 1
fi

echo "Build output: $OUT_DIR"
echo "Logs:         $LOG_DIR"

TEAM_ID_ENTRY=""
if [[ -n "$TEAM_ID" ]]; then
  TEAM_ID_ENTRY="  <key>teamID</key>
  <string>${TEAM_ID}</string>"
fi

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
${TEAM_ID_ENTRY}
  <key>provisioningProfiles</key>
  <dict>
    <key>net.marco-duering.miq</key>
    <string>MIQ_Provisioning</string>
    <key>net.marco-duering.miq.extension</key>
    <string>MIQ_Extension_Provisioning</string>
    <key>net.marco-duering.miq.thumbnail</key>
    <string>MIQ_Thumbnails_Provisioning</string>
  </dict>
</dict>
</plist>
EOF

run_logged "Archiving" "$ARCHIVE_LOG" xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  archive \
  -archivePath "$ARCHIVE_PATH"

run_logged "Exporting signed app (Developer ID)" "$EXPORT_LOG" xcodebuild \
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

run_logged "Submitting for notarization" "$NOTARY_LOG" xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

run_logged "Stapling notarization ticket" "$STAPLE_LOG" xcrun stapler staple "$APP_PATH"

run_logged "Validating stapled ticket" "$VALIDATE_LOG" xcrun stapler validate "$APP_PATH"

run_logged "Gatekeeper assessment" "$GATEKEEPER_LOG" spctl --assess --type execute --verbose=4 "$APP_PATH"

run_logged "Code signature verification" "$CODESIGN_VERIFY_LOG" codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo

echo "SUCCESS"
echo "Notarized app: $APP_PATH"
echo "Build folder:   $OUT_DIR"
echo "Logs folder:    $LOG_DIR"
