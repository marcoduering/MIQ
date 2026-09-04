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
DIST_ZIP="$OUT_DIR/MIQ.app.zip"
EXPORT_PLIST="$OUT_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/MIQ.app"
LOG_DIR="$OUT_DIR/logs"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
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

  echo "----- matching error lines -----" >&2
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
    echo "ERROR: $step_name failed with exit code $status" >&2
    print_log_excerpt "$log_file"
    echo "Full log: $log_file"
    exit "$status"
  fi
}

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "ERROR: NOTARY_PROFILE is required." >&2
  echo "Example: NOTARY_PROFILE=my-notary-profile $0"
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not found." >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "ERROR: xcrun not found." >&2
  exit 1
fi

SIGNING_IDENTITIES="$(security find-identity -v -p codesigning || true)"
if ! grep -q "Developer ID Application" <<< "$SIGNING_IDENTITIES"; then
  echo "ERROR: No 'Developer ID Application' certificate found in keychain." >&2
  echo "Available signing identities:"
  echo "$SIGNING_IDENTITIES"
  exit 1
fi

BUILD_DIR=$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -showBuildSettings 2>/dev/null \
  | awk '/[[:space:]]BUILD_DIR = / { print $3 }')
DERIVED_DATA_DIR="${BUILD_DIR%/Build/Products}"

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
  echo "ERROR: Exported app not found at $APP_PATH" >&2
  exit 1
fi

# --- Sparkle: the feed URL baked into this build must be the production one --
# scripts/dev/sparkle_local_test.sh rewrites SUFeedURL in MIQApp/Info.plist to
# a localhost feed while it builds and restores it afterwards. If that restore
# was skipped (interrupted run) and this script ran on the dirty tree, the
# notarized app would point at localhost and never see a real update. Check
# before spending a notarization round-trip on it.
echo "==> Verifying Sparkle feed URL"
PROD_FEED_URL="https://miq.marco-duering.net/appcast.xml"
BUILT_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$BUILT_FEED_URL" != "$PROD_FEED_URL" ]]; then
  echo "ERROR: exported app's SUFeedURL is '${BUILT_FEED_URL:-<missing>}', expected $PROD_FEED_URL." >&2
  echo "       Restore MIQApp/Info.plist (git diff -- MIQApp/Info.plist) and rerun." >&2
  exit 1
fi
BUILT_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$BUILT_BUNDLE_VERSION" || "$BUILT_BUNDLE_VERSION" == "1" ]]; then
  echo "ERROR: exported app's CFBundleVersion is '${BUILT_BUNDLE_VERSION:-<missing>}'. Sparkle compares this" >&2
  echo "       value, so it must track MARKETING_VERSION (see Config/Shared.xcconfig)." >&2
  exit 1
fi
echo "    ok: $BUILT_FEED_URL (CFBundleVersion $BUILT_BUNDLE_VERSION)"

# Delete intermediate build products — ArchiveIntermediates and regular build
# products in DerivedData — so they don't compete with the exported app for
# lsregister/pluginkit registration on this machine.
echo "==> Removing intermediate build products"
rm -rf "$DERIVED_DATA_DIR/Build/Intermediates.noindex/ArchiveIntermediates/MIQ"
rm -rf "$DERIVED_DATA_DIR/Build/Products/Release-macosx"
rm -rf "$DERIVED_DATA_DIR/Build/Products/Debug-macosx"

echo "==> Packaging app for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

run_logged "Submitting for notarization" "$NOTARY_LOG" xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

run_logged "Stapling notarization ticket" "$STAPLE_LOG" xcrun stapler staple "$APP_PATH"

run_logged "Validating stapled ticket" "$VALIDATE_LOG" xcrun stapler validate "$APP_PATH"

run_logged "Gatekeeper assessment" "$GATEKEEPER_LOG" spctl --assess --type execute --verbose=4 "$APP_PATH"

run_logged "Code signature verification" "$CODESIGN_VERIFY_LOG" codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# --- Sparkle: the nested helper code must each be independently valid ---------
# Sparkle's updater is not one binary: Autoupdate and Updater.app run after MIQ
# has quit, and Installer.xpc runs OUTSIDE the app sandbox (that is the whole
# point of it — a sandboxed app cannot write /Applications). Gatekeeper checks
# each of them on its own at that moment, long after the app's own signature was
# verified, so a nested item that failed to re-sign during export surfaces as an
# update that dies mid-install rather than as a build error.
echo "==> Verifying nested Sparkle code"
SPARKLE_VERSION_DIR="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/Current"
if [[ -d "$SPARKLE_VERSION_DIR" ]]; then
  for nested in Autoupdate Updater.app XPCServices/Installer.xpc; do
    nested_path="$SPARKLE_VERSION_DIR/$nested"
    if [[ ! -e "$nested_path" ]]; then
      echo "ERROR: Sparkle component missing from the exported app: $nested" >&2
      exit 1
    fi
    if ! codesign --verify --strict "$nested_path" 2>&1; then
      echo "ERROR: Sparkle component failed signature verification: $nested" >&2
      exit 1
    fi
    echo "    ok: $nested"
  done
else
  echo "ERROR: Sparkle.framework is not embedded in the exported app." >&2
  echo "       In-app updates would silently not exist in this release." >&2
  exit 1
fi

# The two mach-lookup exceptions are what let the sandboxed app reach the
# installer service. Without them the update downloads and then fails to
# install, with no error until the user tries.
echo "==> Verifying Sparkle installer entitlements"
APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
for service in "-spks" "-spki"; do
  if ! grep -q "net.marco-duering.miq${service}" <<< "$APP_ENTITLEMENTS"; then
    echo "ERROR: missing mach-lookup entitlement net.marco-duering.miq${service}" >&2
    exit 1
  fi
  echo "    ok: net.marco-duering.miq${service}"
done

# --- App Group: the failure this project has actually been bitten by ----------
# `codesign --verify` does NOT catch a profile/certificate mismatch. If the
# embedded provisioning profile does not AUTHORIZE the app group, the sandbox
# drops the entitlement at runtime with no error and no crash — the thumbnail
# extension just silently reads MIQConfig.Defaults instead of the user's
# settings. Check the profile itself, not the signature.
echo "==> Verifying App Group is authorized by the embedded profiles"
APP_GROUP="group.net.marco-duering.miq"
for bundle in \
  "$APP_PATH" \
  "$APP_PATH/Contents/PlugIns/MIQQuickLookExtension.appex" \
  "$APP_PATH/Contents/PlugIns/MIQThumbnailExtension.appex"
do
  profile="$bundle/Contents/embedded.provisionprofile"
  if [[ ! -f "$profile" ]]; then
    echo "ERROR: no embedded.provisionprofile in $(basename "$bundle")" >&2
    exit 1
  fi
  # plutil splits a key path on dots, so it cannot address the dotted
  # com.apple.security.application-groups key directly — extract Entitlements
  # and grep instead.
  if ! security cms -D -i "$profile" 2>/dev/null \
       | plutil -extract Entitlements xml1 -o - - 2>/dev/null \
       | grep -q "$APP_GROUP"; then
    echo "ERROR: $(basename "$bundle") — embedded profile does NOT authorize $APP_GROUP." >&2
    echo "       The extension would silently fall back to MIQConfig.Defaults." >&2
    exit 1
  fi
  echo "    ok: $(basename "$bundle")"
done

# The ZIP submitted for notarization was created before stapling, so it lacks
# the embedded ticket. Create the distribution zip from the stapled app now.
echo "==> Creating distribution zip (stapled)"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_ZIP"

# Register the exported extensions on this machine. The lsregister/pluginkit
# steps mirror build.sh: unregister every competing MIQ.app copy, register this
# one, then activate both extensions (thumbnail first — preview last, so the
# preview extension wins the contested .gz UTI binding).
APPEX="$APP_PATH/Contents/PlugIns/MIQQuickLookExtension.appex"
THUMB_APPEX="$APP_PATH/Contents/PlugIns/MIQThumbnailExtension.appex"

while IFS= read -r other; do
  [[ -z "$other" || "$other" == "$APP_PATH" ]] && continue
  "$LSREGISTER" -u "$other" 2>/dev/null || true
done < <("$LSREGISTER" -dump 2>/dev/null \
  | grep -oE 'path: +/[^ ]*MIQ\.app' \
  | sed 's/path: *//' \
  | sort -u)

"$LSREGISTER" -f -R -trusted "$APP_PATH" || true

while IFS= read -r stale; do
  [[ "$stale" == "$APPEX" || "$stale" == "$THUMB_APPEX" ]] && continue
  pluginkit -r "$stale" 2>/dev/null || true
done < <(pluginkit -m -v 2>/dev/null \
  | grep -E "net\.marco-duering\.miq\.(extension|thumbnail)" \
  | awk -F'\t' '{print $NF}')

if [[ -d "$THUMB_APPEX" ]]; then
  pluginkit -a "$THUMB_APPEX"
fi
pluginkit -a "$APPEX"

qlmanage -r
qlmanage -r cache

for proc in QuickLookUIService QuickLookSatellite quicklookd com.apple.quicklook.ThumbnailsAgent; do
  killall "$proc" >/dev/null 2>&1 || true
done

echo

echo "SUCCESS"
echo "Notarized app:    $APP_PATH"
echo "Distribution zip: $DIST_ZIP"
echo "Build folder:     $OUT_DIR"
echo "Logs folder:      $LOG_DIR"
