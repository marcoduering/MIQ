# Releasing MIQ

Maintainer-only. Every step below is scripted; this page is the order they run in and the checks between them. Nothing here is optional: the in-app updater (Sparkle) only works if the GitHub release, the appcast feed and the Homebrew cask all describe the same build.

## One-time setup

- Developer ID Application certificate in the login keychain, plus the three manual provisioning profiles (`MIQ_Provisioning`, `MIQ_Extension_Provisioning`, `MIQ_Thumbnails_Provisioning`).
- A notarytool credentials profile:
  ```bash
  xcrun notarytool store-credentials "my-notary-profile" --apple-id "APPLE_ID_EMAIL" --team-id "TEAM_ID" --password "app-specific-password"
  ```
- `gh` installed and authenticated (`brew install gh && gh auth login`).
- The Sparkle private EdDSA key in the login keychain (account `ed25519`), created once with Sparkle's `generate_keys`. Its public half is `SUPublicEDKey` in `MIQApp/Info.plist`. **This key is the one unrecoverable asset in the project**: lose it and no installed copy can ever update again. Keep an offline export (`generate_keys -x <file>`) somewhere safe.
- A local checkout of the Homebrew tap (`github.com/marcoduering/homebrew-miq`). Never edit the copy under `/opt/homebrew/Library/Taps/`; `brew update` resets it.

## Before tagging

1. Bump `MARKETING_VERSION` in `Config/Shared.xcconfig` (never in Xcode's General tab). `CFBundleVersion` follows it automatically; Sparkle compares that value, so a release without a bump is invisible to every installed copy.
2. Run the tests from another directory:
   ```bash
   cd /tmp && swift test --package-path /path/to/MIQ --scratch-path /tmp/miq-build
   ```
3. Optional but recommended for slicing/decoding changes: `./scripts/perf/profile.sh` and compare against the baseline.
4. Optional: exercise the update flow end to end with `./scripts/dev/sparkle_local_test.sh setup` / `serve` / `cleanup`. When done, confirm the tree is clean; that script edits `MIQApp/Info.plist` and `Config/Shared.xcconfig` and restores them, and a leftover localhost feed URL must not be released (`release_notarize.sh` refuses to notarize one).
5. Make sure `git status` is clean and `MIQ.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is committed. It pins the exact Sparkle version; without it a fresh checkout resolves to the newest 2.x and the shipped updater would differ from the tested one.
6. Commit, tag and push:
   ```bash
   git tag vX.Y.Z && git push origin main vX.Y.Z
   ```

## Release steps, in order

### 1. Build, sign, notarize, staple

```bash
NOTARY_PROFILE=my-notary-profile ./scripts/release_notarize.sh
```

Produces `build/release-<timestamp>/MIQ.app.zip` (the stapled distribution artifact). The script fails, rather than warns, if any of these is wrong: Sparkle's nested Autoupdate / Updater.app / Installer.xpc signatures, the `-spks` / `-spki` mach-lookup entitlements, the App Group authorization in all three embedded profiles, the production feed URL, or a non-bumped `CFBundleVersion`.

### 2. GitHub release

```bash
./scripts/release_github.sh            # draft; requires HEAD on the exact tag
```

Edit the release notes on GitHub and publish. The asset must stay named `MIQ.app.zip`: both the Homebrew cask and the appcast enclosure URL point at `releases/download/vX.Y.Z/MIQ.app.zip`. The script prints the sha256 for the cask; keep it for step 4.

`--publish` skips the draft. Do that only if the notes are already written, because step 3 links to this page.

### 3. Appcast (the Sparkle feed)

```bash
./scripts/release_appcast.sh
git add docs/appcast.xml && git commit -m "Appcast X.Y.Z" && git push
```

This signs the zip with the EdDSA key and adds an item to `docs/appcast.xml`, which GitHub Pages serves at `https://miq.marco-duering.net/appcast.xml`. Existing items are preserved as they are; only the new archive is staged, on purpose (see the header of the script for why an old zip next to the new one would corrupt older items' URLs).

The feed must be live before users check for updates. Confirm after Pages has deployed (usually under a minute):

```bash
curl -fsSL https://miq.marco-duering.net/appcast.xml | grep -c "<item>"
```

Step 3 comes after step 2 because Sparkle downloads the enclosure straight from the GitHub release asset; a draft release's asset URL returns 404.

### 4. Homebrew cask

In your checkout of the tap, update `version` and `sha256` in `Casks/miq.rb` (sha256 from step 2), then `brew audit --cask --strict Casks/miq.rb`, commit and push. Users on Homebrew get the new version via `brew upgrade --cask miq --greedy`; the cask carries `auto_updates true`, so a plain `brew upgrade` leaves it to Sparkle.

`auto_updates true` and the Sparkle-capable app must land in the **same** cask commit. Added earlier, it would stop `brew upgrade` from delivering a version that cannot yet self-update; added later, `brew upgrade --cask miq` would silently downgrade a self-updated app and Sparkle would immediately re-offer the newer one.

### 5. Verify the update path

Keep the previous release's `MIQ.app.zip` handy (or download it from the previous GitHub release). Install it, open it, choose **MIQ → Check for Updates…**. Sparkle must offer the new version, download, install over `/Applications/MIQ.app` and relaunch. Then press Space on a `.nii.gz` in Finder to confirm Quick Look still answers from the updated bundle (no `pluginkit` / `lsregister` / `qlmanage` should be needed).

## Notes for the first Sparkle release (1.4.0)

- No installed copy older than 1.4.0 contains Sparkle. Those users update manually one last time (GitHub download or `brew upgrade --cask miq`), after which the app self-updates.
- `docs/appcast.xml` does not exist before this release. Until step 3 is pushed, **Check for Updates…** in 1.4.0 shows a Sparkle error about the feed. Do step 3 before announcing the release.
- The cask commit for 1.4.0 is the one that adds `auto_updates true` (step 4). Do not push that stanza on its own beforehand.

## If something goes wrong

- **Update downloads but dies at install time**: the `-spks` / `-spki` mach-lookup entitlements or `SUEnableInstallerLauncherService` are missing or the nested Sparkle code failed to re-sign. `release_notarize.sh` checks all of these; a hand-built zip does not.
- **Sparkle says the update is not newer**: `CFBundleVersion` did not increase. Bump `MARKETING_VERSION` and cut a new release; feed items cannot be edited into existence.
- **Signature mismatch on download**: the appcast was generated with a different EdDSA key than `SUPublicEDKey` in the shipped app. Regenerate with the correct keychain key. If the key is genuinely lost, a new key means every installed copy must update manually once more; document it in the release notes.
- **Wrong or corrupt appcast**: `docs/appcast.xml` is plain XML in git. Revert the commit and re-run step 3; the script rebuilds the item for the current archive from scratch.
