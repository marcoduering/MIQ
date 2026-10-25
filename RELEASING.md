# Releasing MIQ

Maintainer-only. `scripts/release.sh` runs the whole release; this page covers what it needs, what it does, and how to recover. The reasoning behind the Sparkle and Homebrew rules lives in CLAUDE.md.

## One-time setup

- Developer ID Application certificate, plus the `MIQ_Provisioning`, `MIQ_Extension_Provisioning` and `MIQ_Thumbnails_Provisioning` profiles.
- A notarytool profile named `MIQ` (or set `NOTARY_PROFILE` to the name you used): `xcrun notarytool store-credentials "MIQ" --apple-id <email> --team-id <id> --password <app-specific>`.
- `DEVELOPMENT_TEAM` set in `LocalSigning.xcconfig`. The script passes it on as the team ID.
- `gh` authenticated (`gh auth login`).
- Sparkle's private EdDSA key in the login keychain, plus an offline export (`generate_keys -x <file>`). It cannot be recovered: lose it and no installed copy can ever update again.
- The tap installed (`brew tap marcoduering/miq`) with push access to `github.com/marcoduering/homebrew-miq`. The script commits the cask there. To use a separate checkout of the tap instead, set `MIQ_TAP_DIR` to it.

## Release

1. **Pull.** A PR merged on GitHub but not pulled would be missing from the release; the script refuses to run while `main` is behind `origin/main`. Commit anything else first, including `Package.resolved`: the only uncommitted changes it accepts are its own.

   ```bash
   git checkout main && git pull --ff-only
   ```

2. **Release.**

   ```bash
   ./scripts/release.sh X.Y.Z
   ```

   It first checks the certificate, notary profile, `gh`, Sparkle key and tap, so a missing one fails before the notarization round trip. Then it opens `build/release-notes/X.Y.Z.md` in `$EDITOR`, seeded with the four sections and, in a comment, the commits since the last tag. Fill in or delete every section; the comment is removed before publishing. Empty notes or a leftover `-` bullet stop the run. To write the notes ahead of time, create that file first and the editor is skipped. The file is gitignored: the GitHub release keeps the published copy.

   After that it runs unattended:

   | Stage | What happens |
   |---|---|
   | `test` | Sets `MARKETING_VERSION` in `Config/Shared.xcconfig` (not committed yet) and runs `swift test`. Sparkle compares `CFBundleVersion`, which follows `MARKETING_VERSION`; never set it in Xcode's General tab. |
   | `notarize` | `release_notarize.sh`: archive, Developer ID export, notarize, staple. Fails on a bad Sparkle signature, missing mach-lookup entitlements, an unauthorized App Group, a non-production feed URL, or an unbumped version. |
   | `appcast` | `release_appcast.sh` adds the item to `docs/appcast.xml`, with the notes embedded. |
   | `commit` | One commit `vX.Y.Z` with the version bump and the appcast, tagged `vX.Y.Z`. The appcast is not part of the app, so the tag points at exactly the source the zip was built from. |
   | `publish` | Pushes the tag, creates the published GitHub release with `MIQ.app.zip` (the asset must keep that name), then pushes `main`. |
   | `cask` | Sets `version` and `sha256` (of the published asset) in `Casks/miq.rb`, runs `brew audit --cask --strict`, commits and pushes the tap. |
   | `feed` | Waits until `https://miq.marco-duering.net/appcast.xml` lists the new version. |

   **The ordering rule:** the feed must never go live before the release it points at, or Sparkle offers an update whose download returns 404. GitHub Pages serves the feed from `main`, so `main` is pushed last, after the release exists.

3. **Verify.** Install the previous release, open it, choose **MIQ → Check for Updates…**, and confirm it installs and relaunches. Then press Space on a `.nii.gz` in Finder.

## If a stage fails

The script stops with the command to resume, for example:

```bash
./scripts/release.sh X.Y.Z --from publish
```

Stages: `notes test notarize appcast commit publish cask feed`. Resuming skips the earlier stages; from `appcast` on, it reuses the newest `build/release-<timestamp>/MIQ.app.zip` that contains version X.Y.Z, so nothing is notarized twice. Before `commit` nothing has left the machine: to abandon a run, `git checkout -- Config/Shared.xcconfig docs/appcast.xml`.

## Fixing release notes after a release

The appcast embeds the notes when it is generated, so editing the GitHub release alone leaves Sparkle showing the old text. Instead:

```bash
./scripts/release.sh X.Y.Z --fix-notes
```

It opens the notes (the local file, or the current release body if the file is gone), then updates the GitHub release and regenerates the appcast item from the published asset, so its signature is unchanged. The appcast change is committed as `Release notes X.Y.Z` and pushed.
