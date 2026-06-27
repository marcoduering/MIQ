#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/release_github.sh              # auto-discovers latest build/release-*/MIQ.app.zip; creates a DRAFT release
#   ./scripts/release_github.sh <path.zip>   # use a specific zip (still draft by default)
#   ./scripts/release_github.sh --publish    # publish immediately instead of creating a draft
#
# Requires:
# - HEAD checked out at an exact git tag
# - gh CLI installed and authenticated (brew install gh && gh auth login)
# - A completed release_notarize.sh run (MIQ.app.zip is the stapled distribution artifact)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DRAFT=true
DIST_ZIP=""

for arg in "$@"; do
  case "$arg" in
    --publish) DRAFT=false ;;
    --*) echo "ERROR: Unknown option: $arg" >&2; exit 1 ;;
    *) DIST_ZIP="$arg" ;;
  esac
done

# Auto-discover latest stapled distribution zip
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
DRAFT_ARGS=(--draft)
[[ "$DRAFT" == false ]] && DRAFT_ARGS=()

echo "==> Tag:      $TAG"
echo "==> Artifact: $DIST_ZIP → $ASSET_NAME"
echo "==> Mode:     $( [[ "$DRAFT" == true ]] && echo 'draft' || echo 'publish' )"

SHA256=$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')

RELEASE_NOTES=$(cat <<'EOF'
**New features:**
-

**Performance improvements:**
-

**Fixes:**
-

**Other:**
-
EOF
)

RELEASE_URL=$(env GH_PAGER=cat gh release create "$TAG" \
  "$DIST_ZIP#$ASSET_NAME" \
  --title "MIQ ${TAG#v}" \
  --notes "$RELEASE_NOTES" \
  "${DRAFT_ARGS[@]+"${DRAFT_ARGS[@]}"}")

echo
echo "SUCCESS"
echo

if [[ "$DRAFT" == true ]]; then
  echo "Release created as DRAFT — review and publish at:"
  echo "  $RELEASE_URL"
  echo
fi

echo "Homebrew cask sha256:"
echo "  $SHA256"
