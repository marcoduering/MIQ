#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Release by default. The project's Release configs use manual Developer ID profiles
# (MIQ_Provisioning, MIQ_Extension_Provisioning, MIQ_Thumbnails_Provisioning) that ALL
# authorize the App Group group.net.marco-duering.miq — required for the thumbnail
# extension to read settings. Debug uses Automatic signing, which cannot provision the
# thumbnail's App Group (no Apple Development profile authorizes it for that App ID), so
# the thumbnail silently falls back to MIQConfig.Defaults. Use --debug only when you
# don't need thumbnail settings to propagate.
CONFIG="Release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="Debug"
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

# Use the project's configured signing (Developer ID manual profiles for Release).
# We intentionally do NOT force CODE_SIGN_IDENTITY="Apple Development" /
# CODE_SIGN_STYLE=Automatic / PROVISIONING_PROFILE_SPECIFIER="": automatic Apple
# Development signing cannot provision the thumbnail extension's App Group (its only
# group-authorizing profile is Developer ID), so it falls back to a wildcard/
# distribution profile that DROPS the app-group entitlement at runtime and the
# thumbnail can no longer read settings. Developer ID code runs locally without
# notarization; notarized distribution is still handled by release_notarize.sh.
xcodebuild \
  -project MIQ.xcodeproj \
  -scheme MIQ \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates \
  build

BUILT_APP="$BUILT_PRODUCTS_DIR/MIQ.app"
APPEX="$BUILT_APP/Contents/PlugIns/MIQQuickLookExtension.appex"
THUMB_APPEX="$BUILT_APP/Contents/PlugIns/MIQThumbnailExtension.appex"
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

  # Remove ALL stale MIQ extension registrations — sibling configs, archive
  # intermediates, old exports — any path that isn't this build. Both the preview
  # and thumbnail extensions are then activated: lsregister discovers them, but
  # `pluginkit -a` is what actually ENABLES them — a fresh build leaves the
  # thumbnail extension dormant (Finder shows no thumbnails) otherwise.
  while IFS= read -r stale; do
    [[ "$stale" == "$APPEX" || "$stale" == "$THUMB_APPEX" ]] && continue
    pluginkit -r "$stale" 2>/dev/null || true
  done < <(pluginkit -m -v 2>/dev/null \
    | grep -E "net\.marco-duering\.miq\.(extension|thumbnail)" \
    | awk -F'\t' '{print $NF}')
  # ORDER MATTERS. `.nii.gz`/`.mif.gz` resolve to the generic, heavily-contested
  # `org.gnu.gnu-zip-archive` UTI, which third-party archive Quick Look extensions
  # (e.g. ArchiveQuickLook) also claim. LaunchServices breaks the tie largely by
  # registration recency, so the PREVIEW extension must be the LAST thing
  # activated — otherwise activating the thumbnail last lets a competitor win the
  # `.gz` preview binding and compressed volumes silently open in the other viewer.
  if [[ -d "$THUMB_APPEX" ]]; then
    pluginkit -a "$THUMB_APPEX"
  fi
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
