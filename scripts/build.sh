#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="Debug"
if [[ "${1:-}" == "--release" ]]; then
  CONFIG="Release"
fi

BUILT_PRODUCTS_DIR=$(xcodebuild \
  -project MIQ.xcodeproj \
  -scheme MIQ \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | awk '/[[:space:]]BUILT_PRODUCTS_DIR = / { print $3 }')

if [[ "$CONFIG" == "Release" ]]; then
  rm -rf "$(dirname "$BUILT_PRODUCTS_DIR")/Debug"
fi

# build.sh always signs with Apple Development so the result runs locally.
# Distribution signing (Developer ID + notarization) is handled by release_notarize.sh.
xcodebuild \
  -project MIQ.xcodeproj \
  -scheme MIQ \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Automatic \
  PROVISIONING_PROFILE_SPECIFIER="" \
  build

PRODUCTS_DIR="$(dirname "$BUILT_PRODUCTS_DIR")"
BUILT_APP="$BUILT_PRODUCTS_DIR/MIQ.app"
APPEX="$BUILT_APP/Contents/PlugIns/MIQQuickLookExtension.appex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

if [[ -d "$APPEX" ]]; then
  # Make THIS build the single authoritative MIQ registration. LaunchServices
  # resolves the shared bundle id (net.marco-duering.miq) to ONE app; stray
  # copies — a release-zip extraction left in /tmp, archive intermediates, the
  # sibling Debug/Release build — otherwise compete and can outrank this build,
  # so quicklookd loads (or fails to find) the wrong extension. Unregister every
  # other MIQ.app LaunchServices knows about, then register this one last.
  while IFS= read -r other; do
    [[ -z "$other" || "$other" == "$BUILT_APP" ]] && continue
    "$LSREGISTER" -u "$other" 2>/dev/null || true
  done < <("$LSREGISTER" -dump 2>/dev/null \
    | grep -oE 'path: +/[^ ]*MIQ\.app' \
    | sed 's/path: *//' \
    | sort -u)

  "$LSREGISTER" -f -R -trusted "$BUILT_APP" || true

  # Sibling-config appex (Debug<->Release) explicitly out, this one in.
  if [[ "$CONFIG" == "Release" ]]; then
    OTHER_APPEX="$PRODUCTS_DIR/Debug/MIQ.app/Contents/PlugIns/MIQQuickLookExtension.appex"
  else
    OTHER_APPEX="$PRODUCTS_DIR/Release/MIQ.app/Contents/PlugIns/MIQQuickLookExtension.appex"
  fi
  pluginkit -r "$OTHER_APPEX" 2>/dev/null || true
  pluginkit -a "$APPEX"
fi

qlmanage -r
qlmanage -r cache

# qlmanage -r alone leaves quicklookd / QuickLookUIService on stale state once
# the appex binary is replaced in place by a rebuild — restart them so the new
# build is actually picked up. launchd respawns each on demand. (Finder is
# intentionally not restarted; it re-requests previews without a relaunch.)
for proc in QuickLookUIService QuickLookSatellite quicklookd com.apple.quicklook.ThumbnailsAgent; do
  killall "$proc" >/dev/null 2>&1 || true
done
