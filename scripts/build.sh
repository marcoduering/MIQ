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
  | awk '/^\s+BUILT_PRODUCTS_DIR =/ { print $3 }')

xcodebuild \
  -project MIQ.xcodeproj \
  -scheme MIQ \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  build

APPEX="$BUILT_PRODUCTS_DIR/MIQ.app/Contents/PlugIns/MIQQuickLookExtension.appex"
if [[ -d "$APPEX" ]]; then
  # Remove the other configuration's registration to avoid conflicts
  if [[ "$CONFIG" == "Release" ]]; then
    OTHER_APPEX="${BUILT_PRODUCTS_DIR/Release/Debug}/MIQ.app/Contents/PlugIns/MIQQuickLookExtension.appex"
  else
    OTHER_APPEX="${BUILT_PRODUCTS_DIR/Debug/Release}/MIQ.app/Contents/PlugIns/MIQQuickLookExtension.appex"
  fi
  pluginkit -r "$OTHER_APPEX" 2>/dev/null || true
  pluginkit -a "$APPEX"
fi

qlmanage -r
qlmanage -r cache

for proc in QuickLookUIService QuickLookSatellite quicklookd Finder; do
  killall "$proc" >/dev/null 2>&1 || true
done
