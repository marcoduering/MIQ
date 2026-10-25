#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/release_github.sh --notes-file <notes.md>              # auto-discovers latest build/release-*/MIQ.app.zip
#   ./scripts/release_github.sh --notes-file <notes.md> <path.zip>   # use a specific zip
#
# Normally run by scripts/release.sh, which also writes the notes file. The
# release is created PUBLISHED, not as a draft: release.sh pushes the appcast
# (on main) only after this step, so the asset URL is live before any Sparkle
# client can be offered it.
#
# Requires:
# - HEAD checked out at an exact git tag that is already pushed (--verify-tag)
# - gh CLI installed and authenticated (brew install gh && gh auth login)
# - A completed release_notarize.sh run (MIQ.app.zip is the stapled distribution artifact)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DIST_ZIP=""
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file) [[ $# -ge 2 ]] || { echo "ERROR: --notes-file needs a path" >&2; exit 1; }; NOTES_FILE="$2"; shift 2 ;;
    --*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *) DIST_ZIP="$1"; shift ;;
  esac
done

if [[ -z "$NOTES_FILE" || ! -f "$NOTES_FILE" ]]; then
  echo "ERROR: --notes-file <notes.md> is required and must exist." >&2
  exit 1
fi
# Same checks as release_appcast.sh: an empty body or the unedited template
# (a bare "-" bullet) must never reach the release page.
if [[ -z "$(tr -d '[:space:]' < "$NOTES_FILE")" ]]; then
  echo "ERROR: $NOTES_FILE is empty." >&2
  exit 1
fi
if grep -qxE -- '-[[:space:]]*' "$NOTES_FILE"; then
  echo "ERROR: $NOTES_FILE still contains an empty '-' bullet from the template." >&2
  exit 1
fi

# Auto-discover latest stapled distribution zip
if [[ -z "$DIST_ZIP" ]]; then
  # release-<timestamp> only: build/release-notes (release.sh) also matches release-*.
  LATEST_DIR=$(find build -maxdepth 1 -name 'release-[0-9]*' -type d | sort | tail -1)
  if [[ -z "$LATEST_DIR" ]]; then
    echo "ERROR: No build/release-* directory found. Run release_notarize.sh first." >&2
    exit 1
  fi
  DIST_ZIP="$LATEST_DIR/MIQ.app.zip"
  echo "==> Auto-discovered: $DIST_ZIP"
fi

if [[ ! -f "$DIST_ZIP" ]]; then
  echo "ERROR: Distribution zip not found: $DIST_ZIP" >&2
  echo "      MIQ.app.zip is produced by release_notarize.sh after stapling."
  exit 1
fi

# Require HEAD to be on an exact tag
if ! TAG=$(git describe --exact-match --tags HEAD 2>/dev/null); then
  echo "ERROR: HEAD is not on an exact git tag." >&2
  echo "       Tag first: git tag <version> && git push origin <version>"
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found. Install with: brew install gh" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

ASSET_NAME="MIQ.app.zip"

echo "==> Tag:      $TAG"
echo "==> Artifact: $DIST_ZIP → $ASSET_NAME"
echo "==> Notes:    $NOTES_FILE"

SHA256=$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')

# --verify-tag: fail instead of letting gh create the tag from the default
# branch when it has not been pushed — the release must point at the commit
# the zip was built from.
RELEASE_URL=$(env GH_PAGER=cat gh release create "$TAG" \
  "$DIST_ZIP#$ASSET_NAME" \
  --verify-tag \
  --title "MIQ ${TAG#v}" \
  --notes-file "$NOTES_FILE")

echo
echo "SUCCESS"
echo "Release published: $RELEASE_URL"
echo
echo "Homebrew cask sha256:"
echo "  $SHA256"
