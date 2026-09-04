#!/usr/bin/env bash
set -euo pipefail

# End-to-end test of the Sparkle update flow against a LOCAL feed, so the whole
# path — fetch, EdDSA verification, download, install over /Applications/MIQ.app,
# relaunch, and Quick Look still working afterwards — can be exercised without
# cutting a real release.
#
# HTTPS with a self-signed localhost certificate, deliberately: plain HTTP would
# need an NSAllowsLocalNetworking ATS exception in MIQApp/Info.plist, and a
# test-only key sitting in the shipping Info.plist is exactly the sort of thing
# that gets released by accident. Nothing here touches the app's ATS config.
#
# Usage:
#   ./scripts/dev/sparkle_local_test.sh setup     # build both versions + cert + feed
#   ./scripts/dev/sparkle_local_test.sh serve     # run the HTTPS server (foreground)
#   ./scripts/dev/sparkle_local_test.sh cleanup   # remove /Applications copy + test dir
#
# Between setup and serve you must trust the generated certificate once; setup
# prints the exact command.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

TEST_DIR="build/localtest"
SERVE_DIR="$TEST_DIR/www"
PORT=8443
FEED_URL="https://localhost:$PORT/appcast.xml"
PROD_FEED_URL="https://miq.marco-duering.net/appcast.xml"
CERT="$TEST_DIR/localhost.crt"
KEY="$TEST_DIR/localhost.key"
INFO_PLIST="MIQApp/Info.plist"
SHARED_XCCONFIG="Config/Shared.xcconfig"

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
BUILT_APP_GLOB="$DERIVED_DATA/MIQ-*/Build/Products/Release/MIQ.app"

die() { echo "ERROR: $*" >&2; exit 1; }

# Both builds need a non-production feed URL and a different version from each
# other. Rather than keep test-only values in the tree, edit, build, and restore
# under a trap so an interrupted run cannot leave the repo dirty.
restore_sources() {
  [[ -f "$TEST_DIR/.Info.plist.orig" ]] && cp "$TEST_DIR/.Info.plist.orig" "$INFO_PLIST"
  [[ -f "$TEST_DIR/.Shared.xcconfig.orig" ]] && cp "$TEST_DIR/.Shared.xcconfig.orig" "$SHARED_XCCONFIG"
  rm -f "$TEST_DIR/.Info.plist.orig" "$TEST_DIR/.Shared.xcconfig.orig"
}

build_variant() {
  local version="$1" out_zip="$2"
  echo "==> Building $version (feed → $FEED_URL)"
  cp "$INFO_PLIST" "$TEST_DIR/.Info.plist.orig"
  cp "$SHARED_XCCONFIG" "$TEST_DIR/.Shared.xcconfig.orig"
  trap restore_sources EXIT INT TERM

  # BSD sed (macOS): -i needs an explicit backup suffix argument.
  sed -i '' "s|$PROD_FEED_URL|$FEED_URL|" "$INFO_PLIST"
  sed -i '' "s|^MARKETING_VERSION = .*|MARKETING_VERSION = $version|" "$SHARED_XCCONFIG"

  ./scripts/build.sh > "$TEST_DIR/build-$version.log" 2>&1 \
    || { tail -40 "$TEST_DIR/build-$version.log"; die "build failed for $version"; }

  restore_sources
  trap - EXIT INT TERM

  local app
  app=$(ls -d $BUILT_APP_GLOB 2>/dev/null | head -1)
  [[ -n "$app" ]] || die "built app not found"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist")" == "$FEED_URL" ]] \
    || die "built app does not carry the test feed URL"

  # Assert the built app is ACTUALLY the requested version. An incremental build
  # that decides Info.plist is up to date will happily leave the previous
  # version's plist in place, and both zips then contain the same build — a test
  # that appears to pass while proving nothing. Observed once; never silently
  # again.
  local built_version
  built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
  [[ "$built_version" == "$version" ]] \
    || die "built app is $built_version but $version was requested — stale incremental build; run ./scripts/clean.sh and retry"
  echo "    built $built_version"

  rm -f "$out_zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$out_zip"
  echo "    $out_zip"
}

cmd_setup() {
  command -v openssl >/dev/null || die "openssl not found"

  # This script edits tracked source files and restores them. If a previous run
  # was interrupted (Ctrl-C, a failed build, or its stdout being closed early by
  # something like `| head`), those files are still carrying test values — and
  # capturing THOSE as the "original" would bake the localhost feed URL into the
  # tree permanently. Refuse to start from a dirty state.
  grep -q "$PROD_FEED_URL" "$INFO_PLIST" \
    || die "$INFO_PLIST does not contain the production feed URL ($PROD_FEED_URL).
       A previous run probably left test values behind. Restore it before retrying:
         git diff -- $INFO_PLIST"

  mkdir -p "$SERVE_DIR"

  local old_version new_version
  old_version=$(awk -F' = ' '/^MARKETING_VERSION/ {print $2}' "$SHARED_XCCONFIG")
  # Bump the patch component so Sparkle sees a strictly newer CFBundleVersion.
  new_version=$(echo "$old_version" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')
  echo "==> Old (installed): $old_version    New (offered): $new_version"

  echo "==> Generating self-signed localhost certificate"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null

  build_variant "$old_version" "$TEST_DIR/MIQ-old.zip"
  build_variant "$new_version" "$SERVE_DIR/MIQ.app.zip"

  echo "==> Signing the offered update and writing the local appcast"
  local sign_update length signature
  sign_update=$(find "$DERIVED_DATA" -maxdepth 8 -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -type f | head -1)
  [[ -n "$sign_update" ]] || die "sign_update not found — run ./scripts/build.sh once"
  signature=$("$sign_update" -p "$SERVE_DIR/MIQ.app.zip")
  length=$(stat -f%z "$SERVE_DIR/MIQ.app.zip")

  cat > "$SERVE_DIR/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>MIQ (local test)</title>
        <item>
            <title>$new_version</title>
            <sparkle:version>$new_version</sparkle:version>
            <sparkle:shortVersionString>$new_version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<h2>Local test build</h2><p>If you are reading this in Sparkle's update window, the feed fetch and EdDSA verification both worked.</p>]]></description>
            <enclosure url="https://localhost:$PORT/MIQ.app.zip" length="$length" type="application/octet-stream" sparkle:edSignature="$signature" />
        </item>
    </channel>
</rss>
EOF

  echo "==> Installing $old_version to /Applications/MIQ.app"
  rm -rf /Applications/MIQ.app
  ditto -x -k "$TEST_DIR/MIQ-old.zip" /Applications
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

  # CRITICAL for a trustworthy result: the DerivedData copy left by build_variant
  # is the NEW version, and LaunchServices resolves net.marco-duering.miq to ONE
  # app. Left registered, it can answer Space and make the test look like the
  # update landed when nothing was installed. Evict every other copy first, the
  # same way build.sh does.
  while IFS= read -r other; do
    [[ -z "$other" || "$other" == "/Applications/MIQ.app" ]] && continue
    "$lsregister" -u "$other" 2>/dev/null || true
  done < <("$lsregister" -dump 2>/dev/null \
    | grep -oE 'path: +/[^ ]*MIQ\.app' \
    | sed 's/path: *//' \
    | sort -u)

  "$lsregister" -f -R -trusted /Applications/MIQ.app || true

  local appex="/Applications/MIQ.app/Contents/PlugIns/MIQQuickLookExtension.appex"
  local thumb="/Applications/MIQ.app/Contents/PlugIns/MIQThumbnailExtension.appex"
  while IFS= read -r stale; do
    [[ "$stale" == "$appex" || "$stale" == "$thumb" ]] && continue
    pluginkit -r "$stale" 2>/dev/null || true
  done < <(pluginkit -m -v 2>/dev/null \
    | grep -E "net\.marco-duering\.miq\.(extension|thumbnail)" \
    | awk -F'\t' '{print $NF}')

  # Thumbnail first, preview LAST — the preview extension must win the contested
  # org.gnu.gnu-zip-archive binding for .nii.gz (see build.sh).
  pluginkit -a "$thumb" 2>/dev/null || true
  pluginkit -a "$appex" 2>/dev/null || true

  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  for proc in QuickLookUIService QuickLookSatellite quicklookd; do
    killall "$proc" >/dev/null 2>&1 || true
  done

  # Post-condition: the tree must be back to production values. A test feed URL
  # left in a tracked file is the one mistake here that could actually ship.
  grep -q "$PROD_FEED_URL" "$INFO_PLIST" \
    || die "INTERNAL: $INFO_PLIST was not restored — it still holds test values. Fix it before committing."
  [[ "$(awk -F' = ' '/^MARKETING_VERSION/ {print $2}' "$SHARED_XCCONFIG")" == "$old_version" ]] \
    || die "INTERNAL: $SHARED_XCCONFIG was not restored to $old_version."

  cat <<EOF

SETUP COMPLETE

  Installed : /Applications/MIQ.app  ($old_version)
  Offered   : $new_version via $FEED_URL

NEXT — trust the test certificate once (asks for your password):

  sudo security add-trusted-cert -d -r trustRoot \\
    -k /Library/Keychains/System.keychain "$ROOT_DIR/$CERT"

THEN, in another terminal:

  ./scripts/dev/sparkle_local_test.sh serve

THEN, in the app:

  open -a /Applications/MIQ.app
  MIQ menu → "Check for Updates…" → Install Update

WHAT TO CHECK AFTERWARDS:

  1. /Applications/MIQ.app is now $new_version:
       defaults read /Applications/MIQ.app/Contents/Info.plist CFBundleShortVersionString
  2. Quick Look STILL WORKS with no pluginkit/lsregister/qlmanage run by hand —
     press Space on a .nii.gz in Finder. Confirm which build answered:
       pluginkit -m -v | grep miq
  3. Your settings survived (Settings → Image Display still shows your values).

WHEN DONE:

  ./scripts/dev/sparkle_local_test.sh cleanup
  sudo security delete-certificate -c localhost /Library/Keychains/System.keychain
EOF
}

cmd_serve() {
  [[ -f "$SERVE_DIR/appcast.xml" ]] || die "run 'setup' first"

  # A previous run's server can outlive its shell (orphaned to PID 1), and the
  # bare Python traceback for that is "OSError: [Errno 48] Address already in
  # use", which says nothing about what to do. Name the culprit instead.
  local holder
  holder=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)
  if [[ -n "$holder" ]]; then
    echo "ERROR: port $PORT is already in use by PID $holder:" >&2
    ps -o pid,lstart,command -p "$holder" >&2 || true
    echo >&2
    echo "If that is a leftover server from an earlier run, stop it with:" >&2
    echo "  kill $holder" >&2
    exit 1
  fi

  echo "Serving $SERVE_DIR at https://localhost:$PORT/ (Ctrl-C to stop)"
  python3 - "$SERVE_DIR" "$PORT" "$CERT" "$KEY" <<'PY'
import http.server, ssl, sys, functools
directory, port, cert, key = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PY
}

cmd_cleanup() {
  # Only a prior `setup` puts a test build in /Applications. Without its state
  # directory, whatever is installed there is the user's real copy — leave it.
  [[ -d "$TEST_DIR" ]] || die "$TEST_DIR does not exist, so nothing was set up by this script.
       Refusing to delete /Applications/MIQ.app (it is not a test install)."
  echo "==> Removing /Applications/MIQ.app and $TEST_DIR"
  rm -rf /Applications/MIQ.app "$TEST_DIR"
  echo "==> Restoring the DerivedData build as the registered copy"
  ./scripts/build.sh >/dev/null 2>&1 || echo "    (build.sh failed; run it by hand)"
  git diff --stat -- "$INFO_PLIST" "$SHARED_XCCONFIG"
  echo "Done. Remember to remove the trusted test certificate:"
  echo "  sudo security delete-certificate -c localhost /Library/Keychains/System.keychain"
}

case "${1:-}" in
  setup)   cmd_setup ;;
  serve)   cmd_serve ;;
  cleanup) cmd_cleanup ;;
  *) echo "Usage: $0 {setup|serve|cleanup}" >&2; exit 1 ;;
esac
