#!/usr/bin/env bash
set -euo pipefail

# One-command release. The running order and the reasons behind it are in
# RELEASING.md.
#
# Usage:
#   ./scripts/release.sh X.Y.Z                   # full release
#   ./scripts/release.sh X.Y.Z --from <stage>    # resume after a failure
#   ./scripts/release.sh X.Y.Z --fix-notes       # correct the notes of a published release
#
# Stages, in order: notes test notarize appcast commit publish cask feed
#
#   notes     build/release-notes/X.Y.Z.md (gitignored). Created from a template
#             and opened in $EDITOR if missing, used as is if already written.
#   test      bump MARKETING_VERSION (not committed yet), run swift test.
#   notarize  release_notarize.sh on the bumped working tree.
#   appcast   release_appcast.sh writes docs/appcast.xml.
#   commit    ONE commit "vX.Y.Z" (version bump + appcast), tagged vX.Y.Z.
#   publish   push the tag, create the published GitHub release, push main.
#   cask      version + sha256 in the Homebrew tap, brew audit, commit, push.
#   feed      wait until GitHub Pages serves the new feed item.
#
# The build runs on the uncommitted bump and is committed together with the
# appcast it produced: docs/appcast.xml is not part of the app, so the tagged
# commit is exactly the source the zip was built from, and no separate
# "Appcast" commit is needed.
#
# Environment:
#   NOTARY_PROFILE  notarytool keychain profile (default: notary)
#   TEAM_ID         Developer ID team (default: 78X8DKBN7C)
#   MIQ_TAP_DIR     tap checkout to commit the cask in (default: ~/Git/homebrew-miq).
#                   Never the installed tap: brew update hard-resets it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TAP_NAME="marcoduering/miq"
CASK_FILE="Casks/miq.rb"
APPCAST="docs/appcast.xml"
XCCONFIG="Config/Shared.xcconfig"
FEED_URL="https://miq.marco-duering.net/appcast.xml"
NOTES_DIR="build/release-notes"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
TEAM_ID="${TEAM_ID:-78X8DKBN7C}"
STAGES=(notes test notarize appcast commit publish cask feed)

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

usage() {
  sed -n '7,10p' "${BASH_SOURCE[0]}" | sed 's/^# //'
  echo
  echo "Stages: ${STAGES[*]}"
  exit 1
}

V=""
FROM="notes"
FIX_NOTES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -ge 2 ]] || usage; FROM="$2"; shift 2 ;;
    --fix-notes) FIX_NOTES=true; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$V" ]] || usage; V="$1"; shift ;;
  esac
done

[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
TAG="v$V"
NOTES_FILE="$NOTES_DIR/$V.md"

stage_index() {
  local stage="$1" i
  for i in "${!STAGES[@]}"; do
    if [[ "${STAGES[$i]}" == "$stage" ]]; then echo "$i"; return 0; fi
  done
  return 1
}
FROM_INDEX="$(stage_index "$FROM")" || die "unknown stage '$FROM' (one of: ${STAGES[*]})"

# True when <stage> is part of this run (it is FROM or comes after it).
runs() { local stage="$1"; [[ "$FROM_INDEX" -le "$(stage_index "$stage")" ]]; }

STAGING="$(mktemp -d)"
CURRENT_STAGE=""
# Any failure inside a stage, including a failing command under set -e, ends
# with the exact resume command.
on_exit() {
  local status=$?
  rm -rf "$STAGING"
  if [[ $status -ne 0 && -n "$CURRENT_STAGE" ]]; then
    echo "Stopped in stage '$CURRENT_STAGE'. After fixing the cause: $0 $V --from $CURRENT_STAGE" >&2
  fi
}
trap on_exit EXIT
# The notes as published: NOTES_FILE with its <!-- --> comments removed.
CLEAN_NOTES="$STAGING/notes.md"
ZIP=""

# --- Helpers -------------------------------------------------------------------

# version_gt A B: A > B, comparing X.Y.Z numerically.
version_gt() {
  local lhs="$1" rhs="$2"
  local -a a b
  local i
  IFS=. read -r -a a <<< "$lhs"
  IFS=. read -r -a b <<< "$rhs"
  for i in 0 1 2; do
    if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
    if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
  done
  return 1
}

# Fails on any working-tree change other than the given paths. Untracked files
# count: Package.swift globs its source directories, so a stray file could end
# up in the tested build without being in the tagged commit.
check_tree() {
  local allowed=" ${*-} " line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$allowed" == *" ${line:3} "* ]] \
      || die "unexpected change in the working tree: '$line'. Commit, stash or remove it first."
  done < <(git status --porcelain --untracked-files=normal)
}

# main must contain everything on origin/main: a PR merged on GitHub but not
# pulled would otherwise be silently missing from the release.
check_main_synced() {
  [[ "$(git symbolic-ref --short -q HEAD || true)" == "main" ]] || die "not on main."
  git fetch -q origin main
  git merge-base --is-ancestor origin/main HEAD \
    || die "main is behind origin/main. Run: git pull --ff-only"
}

zip_version() {
  local zip="$1"
  unzip -p "$zip" 'MIQ.app/Contents/Info.plist' > "$STAGING/Info.plist" 2>/dev/null || return 0
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGING/Info.plist" 2>/dev/null || true
}

# The newest build/release-<timestamp>/MIQ.app.zip that actually contains
# version V. The pattern starts with a digit so build/release-notes is skipped.
find_zip() {
  local dir
  for dir in $(find build -maxdepth 1 -name 'release-[0-9]*' -type d 2>/dev/null | sort -r); do
    if [[ -f "$dir/MIQ.app.zip" && "$(zip_version "$dir/MIQ.app.zip")" == "$V" ]]; then
      echo "$dir/MIQ.app.zip"
      return 0
    fi
  done
  return 1
}

write_notes_template() {
  local prev
  prev="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  cat <<'EOF'
**New features:**
-

**Performance improvements:**
-

**Fixes:**
-

**Other:**
-

EOF
  echo "<!-- Removed before publishing. Fill in or delete every section above."
  echo "Commits since ${prev:-the first commit}:"
  git log --no-merges --format='- %s' ${prev:+"$prev..HEAD"}
  echo "-->"
}

require_tty() {
  [[ -t 0 && -t 1 ]] || die "no terminal to open an editor for $NOTES_FILE. Write it first."
}

open_editor() {
  require_tty
  # Unquoted on purpose: EDITOR may carry arguments, e.g. "code --wait".
  ${VISUAL:-${EDITOR:-vi}} "$NOTES_FILE"
}

# Strips the <!-- --> comments, then refuses empty notes or the unedited
# template (a bare "-" bullet, which no real notes contain).
prepare_notes() {
  [[ -f "$NOTES_FILE" ]] || die "$NOTES_FILE not found. Run from the 'notes' stage to create it."
  perl -0pe 's/<!--.*?-->\n?//gs' "$NOTES_FILE" > "$CLEAN_NOTES"
  [[ -n "$(tr -d '[:space:]' < "$CLEAN_NOTES")" ]] \
    || die "$NOTES_FILE has no notes. Write them, then re-run."
  if grep -qxE -- '-[[:space:]]*' "$CLEAN_NOTES"; then
    die "$NOTES_FILE still has an empty '-' bullet. Fill in or delete every section, then re-run."
  fi
}

# Writes the cask in place. Exactly one version and one sha256 line are
# expected, so a cask restructured into something this edit does not
# understand fails loudly instead of being half-updated.
update_cask() {
  local cask="$1" sha="$2"
  [[ "$(grep -cE '^[[:space:]]*version "' "$cask" || true)" == 1 \
     && "$(grep -cE '^[[:space:]]*sha256 "' "$cask" || true)" == 1 ]] \
    || die "$cask does not have exactly one version and one sha256 line."
  sed -i '' -E \
    -e "s/^([[:space:]]*version )\"[^\"]*\"/\1\"$V\"/" \
    -e "s/^([[:space:]]*sha256 )\"[^\"]*\"/\1\"$sha\"/" \
    "$cask"
}

# Audits by name against the installed tap: the TAP_DIR cask is copied in for
# the audit and the installed tap restored afterwards.
# On failure the edit is reverted, so a resume starts from a clean tap.
audit_cask() {
  local status=0
  if [[ "$TAP_DIR" -ef "$INSTALLED_TAP" ]]; then
    HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask --strict "$TAP_NAME/miq" || status=$?
  else
    cp "$TAP_DIR/$CASK_FILE" "$INSTALLED_TAP/$CASK_FILE"
    HOMEBREW_NO_AUTO_UPDATE=1 brew audit --cask --strict "$TAP_NAME/miq" || status=$?
    git -C "$INSTALLED_TAP" checkout -- "$CASK_FILE"
  fi
  if [[ $status -ne 0 ]]; then
    git -C "$TAP_DIR" checkout -- "$CASK_FILE"
    die "brew audit failed."
  fi
}

# --- Preflight -------------------------------------------------------------------
# Everything that can be checked up front is, so a missing credential fails now
# rather than after a multi-minute notarization round trip.

preflight() {
  step "Preflight ($TAG, from '$FROM')"

  command -v gh >/dev/null 2>&1 || die "gh not found (brew install gh)."
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)."

  if runs commit; then
    check_main_synced
    check_tree "$XCCONFIG" "$APPCAST"
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
       || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
      die "tag $TAG already exists. If an earlier run got past 'commit', resume with: $0 $V --from publish"
    fi
    # Compared against the committed files: a failed earlier run may have
    # left the working copies already bumped.
    local committed released
    committed="$(git show "HEAD:$XCCONFIG" | awk -F' = ' '/^MARKETING_VERSION/ { print $2 }')"
    released="$(git show "HEAD:$APPCAST" | grep -m1 -o '<sparkle:version>[^<]*' | sed 's/.*>//' || true)"
    if version_gt "$committed" "$V"; then
      die "$XCCONFIG on main is already at $committed, newer than $V."
    fi
    if [[ -n "$released" ]] && ! version_gt "$V" "$released"; then
      die "$V is not newer than the latest released version $released."
    fi
  elif runs publish; then
    check_main_synced
    check_tree
    [[ "$(git describe --exact-match --tags HEAD 2>/dev/null || true)" == "$TAG" ]] \
      || die "HEAD is not tagged $TAG. Resume from 'commit' instead."
  fi

  if runs notarize; then
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    [[ "$identities" == *"Developer ID Application"* ]] \
      || die "no 'Developer ID Application' certificate in the keychain."
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || die "notarytool profile '$NOTARY_PROFILE' is missing or its credentials are rejected.
       Store it: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <email> --team-id <id> --password <app-specific>
       or set NOTARY_PROFILE to the name you used."
  fi

  if runs appcast; then
    security find-generic-password -s "https://sparkle-project.org" -a ed25519 >/dev/null 2>&1 \
      || die "Sparkle's private EdDSA key (account ed25519) is not in the keychain."
  fi

  if runs cask; then
    command -v brew >/dev/null 2>&1 || die "brew not found."
    INSTALLED_TAP="$(brew --repository "$TAP_NAME")"
    TAP_DIR="${MIQ_TAP_DIR:-$HOME/Git/homebrew-miq}"
    [[ -d "$INSTALLED_TAP/.git" ]] || die "tap $TAP_NAME is not installed. Run: brew tap $TAP_NAME"
    [[ -f "$TAP_DIR/$CASK_FILE" ]] || die "$TAP_DIR/$CASK_FILE not found (set MIQ_TAP_DIR?)."
    [[ -z "$(git -C "$TAP_DIR" status --porcelain)" ]] \
      || die "the tap checkout $TAP_DIR has uncommitted changes."
    git -C "$TAP_DIR" fetch -q
    git -C "$TAP_DIR" merge-base --is-ancestor '@{u}' HEAD \
      || die "the tap checkout $TAP_DIR is behind its upstream. Run: git -C \"$TAP_DIR\" pull --ff-only"
    git -C "$TAP_DIR" push --dry-run -q >/dev/null 2>&1 \
      || die "cannot push from $TAP_DIR. Check its remote and credentials."
  fi

  echo "    ok"
}

# --- Stages ----------------------------------------------------------------------

stage_notes() {
  step "Release notes: $NOTES_FILE"
  if [[ ! -f "$NOTES_FILE" ]]; then
    require_tty
    mkdir -p "$NOTES_DIR"
    write_notes_template > "$NOTES_FILE"
    open_editor
  else
    echo "    using the existing file"
  fi
}

# Idempotent, so every run that still commits applies it, including a resume.
set_version() {
  sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $V/" "$XCCONFIG"
  grep -qx "MARKETING_VERSION = $V" "$XCCONFIG" || die "could not set MARKETING_VERSION in $XCCONFIG."
}

stage_test() {
  step "Tests"
  (cd /tmp && swift test --package-path "$ROOT_DIR" --scratch-path /tmp/miq-build)
}

stage_notarize() {
  step "Archive, notarize, verify"
  NOTARY_PROFILE="$NOTARY_PROFILE" TEAM_ID="$TEAM_ID" ./scripts/release_notarize.sh
}

stage_appcast() {
  step "Appcast"
  ./scripts/release_appcast.sh --notes-file "$CLEAN_NOTES" "$ZIP"
}

stage_commit() {
  step "Commit and tag $TAG"
  check_tree "$XCCONFIG" "$APPCAST"
  grep -q "<sparkle:version>$V</sparkle:version>" "$APPCAST" || die "$APPCAST has no item for $V."
  git add -- "$XCCONFIG" "$APPCAST"
  git commit -q -m "$TAG"
  git tag "$TAG"
  echo "    $(git log -1 --format='%h %s')"
}

# The ordering rule: the release (and so its asset URL) must be live before the
# feed that points at it. Pushing the tag alone does not touch GitHub Pages;
# pushing main does, so main goes last.
stage_publish() {
  step "Publish $TAG"
  git push -q origin "refs/tags/$TAG"
  local draft
  if draft="$(gh release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null)"; then
    [[ "$draft" == "false" ]] || die "release $TAG exists as a draft. Publish it: gh release edit $TAG --draft=false"
    echo "    release $TAG already published"
  else
    ./scripts/release_github.sh --notes-file "$CLEAN_NOTES" "$ZIP"
  fi
  git push -q origin main
  echo "    pushed main"
}

stage_cask() {
  step "Homebrew cask ($TAP_DIR)"
  # Hash the published asset itself: it is what brew downloads.
  gh release download "$TAG" -p MIQ.app.zip -D "$STAGING/asset" --clobber
  local sha
  sha="$(shasum -a 256 "$STAGING/asset/MIQ.app.zip" | awk '{print $1}')"
  update_cask "$TAP_DIR/$CASK_FILE" "$sha"
  if git -C "$TAP_DIR" diff --quiet -- "$CASK_FILE"; then
    echo "    cask already at $V"
  else
    audit_cask
    git -C "$TAP_DIR" commit -q -m "miq $V" -- "$CASK_FILE"
  fi
  git -C "$TAP_DIR" push -q
  echo "    version $V, sha256 $sha"
}

stage_feed() {
  step "Waiting for $FEED_URL to list $V"
  local body i
  for i in $(seq 1 40); do
    # The query string bypasses the CDN cache in front of GitHub Pages.
    body="$(curl -fsSL --proto '=https' "$FEED_URL?t=$(date +%s)" 2>/dev/null || true)"
    if [[ "$body" == *"<sparkle:version>$V</sparkle:version>"* ]]; then
      echo "    live"
      return 0
    fi
    sleep 15
  done
  die "the feed does not list $V after 10 minutes. Check the GitHub Pages deployment."
}

# --- Fixing the notes of a published release -------------------------------------
# The appcast embeds the notes when it is generated, so editing the GitHub
# release body alone would leave Sparkle showing the old text. This updates
# both, from the same file. The appcast item is regenerated from the published
# asset, so its signature and length stay the same.

fix_notes() {
  step "Fix release notes for $TAG"
  command -v gh >/dev/null 2>&1 || die "gh not found (brew install gh)."
  check_main_synced
  check_tree
  security find-generic-password -s "https://sparkle-project.org" -a ed25519 >/dev/null 2>&1 \
    || die "Sparkle's private EdDSA key (account ed25519) is not in the keychain."
  if [[ ! -f "$NOTES_FILE" ]]; then
    mkdir -p "$NOTES_DIR"
    gh release view "$TAG" --json body --jq .body > "$NOTES_FILE"
    echo "    fetched the current notes from the $TAG release"
  fi
  open_editor
  prepare_notes

  gh release download "$TAG" -p MIQ.app.zip -D "$STAGING/asset" --clobber
  ./scripts/release_appcast.sh --notes-file "$CLEAN_NOTES" "$STAGING/asset/MIQ.app.zip"
  check_tree "$APPCAST"

  gh release edit "$TAG" --notes-file "$CLEAN_NOTES" >/dev/null
  echo "    updated the GitHub release body"
  if git diff --quiet -- "$APPCAST"; then
    echo "    $APPCAST unchanged"
  else
    git commit -q -m "Release notes $V" -- "$APPCAST"
    git push -q origin main
    echo "    pushed $APPCAST"
  fi
}

# --- Main --------------------------------------------------------------------------

if $FIX_NOTES; then
  fix_notes
  exit 0
fi

preflight

run_stage() {
  local stage="$1"
  CURRENT_STAGE="$stage"
  "stage_$stage"
}

if runs notes; then run_stage notes; fi
if runs publish; then prepare_notes; fi
if runs commit; then set_version; fi
if runs test; then run_stage test; fi
if runs notarize; then run_stage notarize; fi
if runs publish; then
  ZIP="$(find_zip)" || die "no build/release-*/MIQ.app.zip containing $V. Resume from 'notarize'."
  echo "==> Distribution zip: $ZIP"
fi
if runs appcast; then run_stage appcast; fi
if runs commit; then run_stage commit; fi
if runs publish; then run_stage publish; fi
if runs cask; then run_stage cask; fi
run_stage feed
CURRENT_STAGE=""

echo
echo "SUCCESS: MIQ $V is released."
echo "Remaining: the manual check in RELEASING.md (update from the previous release, Quick Look)."
