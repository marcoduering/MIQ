#!/usr/bin/env bash
set -euo pipefail

# Regenerate docs/appcast.xml — the Sparkle feed served at
# https://miq.marco-duering.net/appcast.xml (docs/ is the GitHub Pages site).
#
# Usage:
#   ./scripts/release_appcast.sh              # auto-discovers latest build/release-*/MIQ.app.zip
#   ./scripts/release_appcast.sh <path.zip>   # use a specific stapled zip
#
# Run AFTER release_notarize.sh (needs the stapled zip) and AFTER
# release_github.sh (the item's release-notes link points at the GitHub release
# page, which must exist for the link to resolve). Then commit and push
# docs/appcast.xml — nothing is published until GitHub Pages serves it.
# The full sequence is in RELEASING.md.
#
# Requires:
# - The private EdDSA key in the login keychain (account "ed25519"), created by
#   Sparkle's generate_keys. Losing it means no existing install can ever update
#   again — keep an offline backup (generate_keys -x <file>).
# - Sparkle's generate_appcast, which ships in the SPM artifact bundle and is
#   located below.
#
# How the feed accumulates: generate_appcast reads the existing appcast and
# adds an item for each archive in its input directory that the feed doesn't
# have yet. Crucially, it ALSO rewrites the <enclosure> of every existing item
# whose archive IS present, using the current --download-url-prefix (Sparkle
# 2.9.6, generate_appcast/FeedXML.swift, writeAppcast). Items whose archive is
# absent are left untouched. Our enclosure URLs are per-tag GitHub asset URLs,
# so an older archive sitting next to the new one would have its URL rewritten
# to the NEW tag's path — a dead link. Therefore only the archive being
# released is staged, in a throwaway directory; the feed's history is the
# tracked docs/appcast.xml itself, not a directory of old zips.
#
# generate_appcast keeps the newest three versions per branch by default and
# prunes older items; that is intended (Sparkle only ever offers the newest
# applicable item).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPO="marcoduering/MIQ"
APPCAST="docs/appcast.xml"
PRODUCT_LINK="https://miq.marco-duering.net/"
PROD_FEED_URL="https://miq.marco-duering.net/appcast.xml"

DIST_ZIP="${1:-}"

if [[ -z "$DIST_ZIP" ]]; then
  LATEST_DIR=$(find build -maxdepth 1 -name 'release-*' -type d | sort | tail -1)
  if [[ -z "$LATEST_DIR" ]]; then
    echo "ERROR: No build/release-* directory found. Run release_notarize.sh first." >&2
    exit 1
  fi
  DIST_ZIP="$LATEST_DIR/MIQ.app.zip"
  echo "==> Auto-discovered: $DIST_ZIP"
fi

if [[ ! -f "$DIST_ZIP" ]]; then
  echo "ERROR: Distribution zip not found: $DIST_ZIP" >&2
  echo "       MIQ.app.zip is produced by release_notarize.sh after stapling."
  exit 1
fi

# generate_appcast lives in the resolved SPM artifact bundle, whose DerivedData
# directory name is machine-specific — locate it rather than hardcoding it.
DERIVED_DATA="$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || echo "$HOME/Library/Developer/Xcode/DerivedData")"
GENERATE_APPCAST="$(find "$DERIVED_DATA" -maxdepth 8 -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f 2>/dev/null | head -1)"

if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "ERROR: generate_appcast not found under $DERIVED_DATA." >&2
  echo "       Build once (./scripts/build.sh) so Xcode resolves the Sparkle package." >&2
  exit 1
fi

# Everything transient goes in one throwaway directory: the unpacked app (to
# read its version), and the generate_appcast input directory holding ONLY the
# archive being released plus a copy of the current feed (see the note above on
# why older archives must not be present).
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
UNPACK_DIR="$STAGING/unpack"
ARCHIVES_DIR="$STAGING/archives"
mkdir -p "$UNPACK_DIR" "$ARCHIVES_DIR"

# Read the version out of the artifact being published rather than from the
# xcconfig, so the feed can never describe a version the zip doesn't contain.
ditto -x -k "$DIST_ZIP" "$UNPACK_DIR"
APP_PLIST="$UNPACK_DIR/MIQ.app/Contents/Info.plist"
if [[ ! -f "$APP_PLIST" ]]; then
  echo "ERROR: $DIST_ZIP does not contain MIQ.app/Contents/Info.plist" >&2
  exit 1
fi
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PLIST" 2>/dev/null || true)
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true)

if [[ -z "$FEED_URL" || -z "$PUBLIC_KEY" ]]; then
  echo "ERROR: The app in $DIST_ZIP has no SUFeedURL/SUPublicEDKey — it was built without Sparkle." >&2
  exit 1
fi

# A build made while scripts/dev/sparkle_local_test.sh had the tree edited
# carries the localhost feed URL. Publishing that would ship an app that can
# never see a real update.
if [[ "$FEED_URL" != "$PROD_FEED_URL" ]]; then
  echo "ERROR: The app in $DIST_ZIP points at $FEED_URL, not $PROD_FEED_URL." >&2
  echo "       Restore MIQApp/Info.plist and rebuild with release_notarize.sh." >&2
  exit 1
fi

TAG="v$SHORT_VERSION"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"

echo "==> Version:      $SHORT_VERSION (CFBundleVersion $BUNDLE_VERSION)"
echo "==> Feed URL:     $FEED_URL"
echo "==> Download URL: ${DOWNLOAD_PREFIX}MIQ.app.zip"

# Sparkle compares CFBundleVersion. A release that doesn't bump it is invisible
# to every existing install, so fail loudly rather than publish a dead feed.
if [[ "$BUNDLE_VERSION" == "1" ]]; then
  echo "ERROR: CFBundleVersion is '1'. Sparkle compares CFBundleVersion, so a" >&2
  echo "       constant value means no update is ever offered. Config/Shared.xcconfig" >&2
  echo "       should set CURRENT_PROJECT_VERSION = \$(MARKETING_VERSION)." >&2
  exit 1
fi

# GitHub serves every release's asset as "MIQ.app.zip" under its own tag path.
# generate_appcast builds the enclosure URL from --download-url-prefix + the
# archive's filename, and it also keys its extraction cache on that name, so
# stage the zip under a version-qualified name and rewrite the URL back to the
# real asset name afterwards.
ARCHIVE_NAME="MIQ-$SHORT_VERSION.zip"
cp "$DIST_ZIP" "$ARCHIVES_DIR/$ARCHIVE_NAME"

# --- Release notes: embedded in the feed, not linked --------------------------
# Sparkle treats <sparkle:releaseNotesLink> as a URL to LOAD, so pointing it at
# a GitHub release page renders the entire github.com page — global nav, repo
# header, sidebar — around a few lines of notes. SUAppcastItem documents the
# alternative: an embedded <description>. generate_appcast builds one from any
# file sharing the archive's basename, and embeds it as CDATA when the file is
# HTML with no "<!DOCTYPE" or "<body" in it (ArchiveItem.getReleaseNotesAsFragment).
# It must be .html — a .md sibling is classified as markdown and linked, not
# embedded, unless --embed-release-notes is passed.
#
# The notes themselves stay in one place: the GitHub release body you already
# write. GitHub renders its own Markdown, so there is no local converter to
# install or to drift from what the release page shows.
NOTES_HTML="$ARCHIVES_DIR/MIQ-$SHORT_VERSION.html"
RELEASE_BODY=""
if command -v gh >/dev/null 2>&1; then
  RELEASE_BODY="$(gh release view "$TAG" --json body --jq .body 2>/dev/null || true)"
fi

if [[ -n "$RELEASE_BODY" ]]; then
  printf '%s' "$RELEASE_BODY" > "$STAGING/notes.md"
  if gh api --method POST /markdown -f mode=gfm -F text=@"$STAGING/notes.md" \
       > "$STAGING/notes-fragment.html" 2>/dev/null && [[ -s "$STAGING/notes-fragment.html" ]]; then
    # Sparkle renders this in a bare WebView with no stylesheet of its own, so
    # without this block the notes come out as default-size serif. Only colors
    # are set; `color-scheme` lets WebKit paint the canvas to match the OS, so
    # the pane still looks native in both appearances.
    cat > "$NOTES_HTML" <<'CSS'
<style>
body {
  color-scheme: light dark;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  font-size: 12px;
  line-height: 1.45;
  color: #1d1d1f;
  margin: 10px 12px;
}
h1, h2, h3 { font-size: 12.5px; font-weight: 600; margin: 14px 0 4px; }
h1:first-child, h2:first-child, h3:first-child, p:first-child { margin-top: 0; }
p { margin: 0 0 8px; }
ul, ol { margin: 0 0 10px; padding-left: 20px; }
li { margin: 2px 0; }
code {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11px; background: rgba(128,128,128,.14);
  border-radius: 3px; padding: 1px 4px;
}
a { color: #0068da; }
@media (prefers-color-scheme: dark) {
  body { color: #e8e8ed; }
  a { color: #6ba9ff; }
}
</style>
CSS
    cat "$STAGING/notes-fragment.html" >> "$NOTES_HTML"
    echo "==> Release notes: embedded from the $TAG release body ($(wc -c < "$NOTES_HTML" | tr -d ' ') bytes)"
  else
    echo "WARNING: GitHub could not render the release notes; this item will ship without any." >&2
    rm -f "$NOTES_HTML"
  fi
else
  echo "WARNING: no release body found for $TAG — this item will ship without release notes." >&2
  echo "         Write the notes on the GitHub release first, then re-run this script." >&2
fi

# Seed with the published feed so generate_appcast appends to the real history
# instead of starting a fresh one-item feed. First release: no feed yet.
if [[ -f "$APPCAST" ]]; then
  cp "$APPCAST" "$ARCHIVES_DIR/appcast.xml"
  if grep -q "<sparkle:version>$BUNDLE_VERSION</sparkle:version>" "$APPCAST"; then
    echo "==> Note: $APPCAST already has an item for $BUNDLE_VERSION; it will be regenerated in place."
  fi
else
  echo "==> Note: no existing $APPCAST — creating the feed from scratch."
fi

echo "==> Generating appcast"
"$GENERATE_APPCAST" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --link "$PRODUCT_LINK" \
  -o "$ARCHIVES_DIR/appcast.xml" \
  "$ARCHIVES_DIR"

# Rewrite this release's enclosure URL to the asset's real name (see above).
# Only the item for the staged archive can match, so older items are provably
# untouched here. This also asserts the notes ended up embedded rather than
# linked: a leftover <sparkle:releaseNotesLink> would send Sparkle back to
# loading a whole web page in its release-notes pane.
python3 - "$ARCHIVES_DIR/appcast.xml" "$ARCHIVE_NAME" <<'PY'
import sys, xml.etree.ElementTree as ET

path, archive_name = sys.argv[1], sys.argv[2]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")

tree = ET.parse(path)
target = None
for item in tree.getroot().iter("item"):
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    url = enclosure.get("url", "")
    if url.endswith("/" + archive_name):
        enclosure.set("url", url[: -len(archive_name)] + "MIQ.app.zip")
        target = item
        break

if target is None:
    sys.exit(f"ERROR: no appcast item found for {archive_name}")

if target.find(f"{{{SPARKLE}}}releaseNotesLink") is not None:
    sys.exit("ERROR: the item still carries a sparkle:releaseNotesLink. Sparkle would "
             "load that URL instead of showing the embedded notes.")

description = target.find("description")
if description is None or not (description.text or "").strip():
    print("    WARNING: this item has no embedded release notes.", file=sys.stderr)
else:
    print(f"    release notes embedded ({len(description.text)} chars)")

tree.write(path, encoding="utf-8", xml_declaration=True)
print("    rewrote enclosure URL")
PY

# Post-condition: every enclosure in the feed must still point at a
# .../download/<tag>/MIQ.app.zip asset. Anything else means an older item was
# rewritten after all (or the feed was hand-edited into a shape this script
# doesn't understand) — refuse to publish it.
if grep -o 'url="[^"]*"' "$ARCHIVES_DIR/appcast.xml" \
     | grep -v -E "^url=\"https://github.com/$REPO/releases/download/v[0-9][^/\"]*/MIQ\.app\.zip\"$" >/dev/null; then
  echo "ERROR: an enclosure URL in the generated feed is not a per-tag MIQ.app.zip asset URL:" >&2
  grep -o 'url="[^"]*"' "$ARCHIVES_DIR/appcast.xml" >&2
  exit 1
fi

cp "$ARCHIVES_DIR/appcast.xml" "$APPCAST"

echo
echo "SUCCESS"
echo "Appcast written: $APPCAST"
echo
echo "Items now in the feed:"
grep -E "<sparkle:version>|<enclosure|<description" "$APPCAST" | sed 's/^[[:space:]]*/    /'
echo

# The one ordering rule that matters: the GitHub release must be PUBLISHED
# before this feed goes live. The enclosure points at the release asset, and a
# draft release's asset URL 404s for everyone but the maintainer — a live feed
# in front of a draft release means Sparkle offers an update it cannot
# download. release_github.sh (the preceding step) creates the release as a
# draft, so check the state rather than assume it.
RELEASE_STATE="unknown"
if command -v gh >/dev/null 2>&1; then
  RELEASE_STATE="$(gh release view "$TAG" --json isDraft --jq 'if .isDraft then "draft" else "published" end' 2>/dev/null || echo "missing")"
fi

case "$RELEASE_STATE" in
  published)
    echo "GitHub release $TAG: published — its asset URL is live."
    ;;
  draft)
    echo "WARNING: the GitHub release $TAG is still a DRAFT."
    echo "         Publish it BEFORE pushing $APPCAST, or Sparkle will offer an"
    echo "         update whose download URL returns 404:"
    echo "           gh release edit $TAG --draft=false"
    ;;
  missing)
    echo "WARNING: no GitHub release found for $TAG."
    echo "         Run ./scripts/release_github.sh and publish it BEFORE pushing $APPCAST."
    ;;
  *)
    echo "NOTE: gh not installed — confirm the GitHub release $TAG is published"
    echo "      (not a draft) before pushing $APPCAST."
    ;;
esac

echo
echo "Remaining step — publish the feed:"
echo "  git add $APPCAST && git commit -m \"Appcast $SHORT_VERSION\" && git push"
echo "Then confirm GitHub Pages is serving it:"
echo "  curl -fsSL $FEED_URL | grep -c '<item>'"
