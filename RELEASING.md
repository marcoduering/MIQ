# Releasing MIQ

Maintainer-only. This is the running order; the reasoning behind each rule lives in CLAUDE.md (the Sparkle and Homebrew conventions).

## One-time setup

- Developer ID Application certificate, plus the `MIQ_Provisioning`, `MIQ_Extension_Provisioning` and `MIQ_Thumbnails_Provisioning` profiles.
- A notarytool profile: `xcrun notarytool store-credentials "<profile>" --apple-id <email> --team-id <id> --password <app-specific>`.
- `gh` authenticated (`gh auth login`).
- Sparkle's private EdDSA key in the login keychain, account `ed25519`. **Unrecoverable**: lose it and no installed copy can ever update again. Keep an offline export (`generate_keys -x <file>`).
- A checkout of the tap `github.com/marcoduering/homebrew-miq`. Never edit the clone under `/opt/homebrew/Library/Taps/`, which `brew update` resets.

## Release

1. **Bump** `MARKETING_VERSION` in `Config/Shared.xcconfig`, never in Xcode's General tab. Sparkle compares `CFBundleVersion`, which follows it. No bump means no update is ever offered.
2. **Test.** `cd /tmp && swift test --package-path /path/to/MIQ --scratch-path /tmp/miq-build`
3. **Commit and tag** with a clean tree and `Package.resolved` committed: `git tag vX.Y.Z && git push origin main vX.Y.Z`
4. **Notarize.** `NOTARY_PROFILE=<profile> ./scripts/release_notarize.sh` produces `build/release-<timestamp>/MIQ.app.zip`. It fails on a bad Sparkle signature, missing mach-lookup entitlements, an unauthorized App Group, a non-production feed URL, or an unbumped version.
5. **GitHub release.** `./scripts/release_github.sh` creates a draft. Write the notes and publish it. The asset must stay named `MIQ.app.zip`. Keep the printed sha256 for step 7. The notes are not just for the web page: step 6 pulls this body into the appcast, so write them before running it or the update window will have nothing to show.
6. **Appcast.** `./scripts/release_appcast.sh`, then `git add docs/appcast.xml && git commit -m "Appcast X.Y.Z" && git push`. Never push the feed while the release is still a draft; the script checks and warns. Confirm with `curl -fsSL https://miq.marco-duering.net/appcast.xml | grep -c "<item>"`.
7. **Cask.** In the tap checkout set `version` and `sha256` in `Casks/miq.rb`, then audit by name against the installed tap clone and restore it:
   ```bash
   TAP=/opt/homebrew/Library/Taps/marcoduering/homebrew-miq
   cp Casks/miq.rb "$TAP/Casks/miq.rb"
   brew audit --cask --strict marcoduering/miq/miq
   git -C "$TAP" checkout -- Casks/miq.rb
   ```
8. **Verify.** Install the previous release, open it, choose **MIQ → Check for Updates…**, and confirm it installs and relaunches. Then press Space on a `.nii.gz` in Finder.

## First Sparkle release (1.4.0 only)

- Installs older than 1.4.0 have no Sparkle. Those users update manually one last time.
- `docs/appcast.xml` does not exist yet, so **Check for Updates…** errors until step 6 is pushed. Do that before announcing.
- The 1.4.0 cask commit is the one that adds `auto_updates true`. Never push that stanza earlier.

## When it breaks

- **Downloads, then installs nothing.** Missing mach-lookup entitlements, missing `SUEnableInstallerLauncherService`, or unsigned nested Sparkle code. Step 4 catches all three.
- **Says you are up to date.** `CFBundleVersion` did not increase. Cut a new version; feed items cannot be edited into existence.
- **Signature mismatch on download.** The appcast was signed with a key that is not `SUPublicEDKey`.
- **Bad appcast.** It is plain XML in git. Revert the commit and re-run step 6.
