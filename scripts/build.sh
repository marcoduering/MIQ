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
APPEX="$BUILT_PRODUCTS_DIR/MIQ.app/Contents/PlugIns/MIQQuickLookExtension.appex"
if [[ -d "$APPEX" ]]; then
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

# for proc in QuickLookUIService QuickLookSatellite quicklookd Finder; do
#   killall "$proc" >/dev/null 2>&1 || true
# done
