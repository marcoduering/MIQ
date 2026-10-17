# Releasing MIQ

Maintainer-only. This is the running order; the reasoning behind each rule lives in CLAUDE.md (the Sparkle and Homebrew conventions).

## One-time setup

- Developer ID Application certificate, plus the `MIQ_Provisioning`, `MIQ_Extension_Provisioning` and `MIQ_Thumbnails_Provisioning` profiles.
- A notarytool profile: `xcrun notarytool store-credentials "<profile>" --apple-id <email> --team-id <id> --password <app-specific>`.
- `gh` authenticated (`gh auth login`).
- Sparkle's private EdDSA key in the login keychain
- A checkout of the tap `github.com/marcoduering/homebrew-miq`.

## Release

Run everything from the repo root. Set the version once; the later steps use `$V`.

1. **Pull, then bump.** Pull first: a PR merged on GitHub but not pulled is silently missing from the release (1.6.1 shipped without its UI tweaks this way and was withdrawn). Then set `MARKETING_VERSION` in `Config/Shared.xcconfig`, never in Xcode's General tab. Sparkle compares `CFBundleVersion`, which follows it. No bump means no update is ever offered.

   ```bash
   V=X.Y.Z
   git checkout main && git pull --ff-only
   sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $V/" Config/Shared.xcconfig
   ```

2. **Test.**

   ```bash
   REPO=$PWD; (cd /tmp && swift test --package-path "$REPO" --scratch-path /tmp/miq-build)
   ```

3. **Commit and tag** with an otherwise clean tree and `Package.resolved` committed.

   ```bash
   git commit -am "v$V" && git tag "v$V" && git push origin main "v$V"
   ```

   If the push is rejected, `main` moved on GitHub after your pull: delete the local tag (`git tag -d "v$V"`) and go back to step 1.

4. **Notarize.** Produces `build/release-<timestamp>/MIQ.app.zip`. It fails on a bad Sparkle signature, missing mach-lookup entitlements, an unauthorized App Group, a non-production feed URL, or an unbumped version.

   ```bash
   NOTARY_PROFILE=<profile> ./scripts/release_notarize.sh
   ```

5. **GitHub release.** Creates a draft. Write the notes and publish it. The asset must stay named `MIQ.app.zip`. Keep the printed sha256 for step 7. The notes are not just for the web page: step 6 pulls this body into the appcast and refuses to run while the body is empty or still the seeded template.

   ```bash
   ./scripts/release_github.sh
   ```

6. **Appcast.** Never push the feed while the release is still a draft; the script checks and warns.

   ```bash
   ./scripts/release_appcast.sh
   git add docs/appcast.xml && git commit -m "Appcast $V" && git push
   curl -fsSL https://miq.marco-duering.net/appcast.xml | grep -c "<item>"
   ```

7. **Cask.** In the tap checkout set `version` and `sha256` in `Casks/miq.rb`, then audit by name against the installed tap clone and restore it:

   ```bash
   TAP=/opt/homebrew/Library/Taps/marcoduering/homebrew-miq
   cp Casks/miq.rb "$TAP/Casks/miq.rb"
   brew audit --cask --strict marcoduering/miq/miq
   git -C "$TAP" checkout -- Casks/miq.rb
   ```

8. **Verify.** Install the previous release, open it, choose **MIQ → Check for Updates…**, and confirm it installs and relaunches. Then press Space on a `.nii.gz` in Finder.

