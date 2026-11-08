---
name: release
description: Publish a new Clip Builder release — bump the version, build + sign + notarize the beta pkg, tag, and create the GitHub prerelease; bless.sh later makes it stable. Use when asked to release, ship, publish a version, or cut a release of this app.
---

# Release Clip Builder

One command does the whole pipeline — do NOT reimplement its steps by hand:

```bash
scripts/release.sh
```

Every release is a **beta**. It bumps versions in `project.pbxproj`,
builds/signs/notarizes/staples the beta pkg (`CHANNEL=beta scripts/make_pkg.sh`
→ `dist/ClipBuilder-Beta-<version>.pkg`), commits, tags `v<version>`, pushes,
and creates the GitHub release **as a prerelease** titled "Clip Builder Beta
<version>" with that pkg attached (`--generate-notes`). Stable apps skip
prereleases; beta apps update to it. It does not touch the Getting Started
guide: `scripts/bless.sh` points the guide at a release when it becomes
stable (below). Run it from the repo root with a **long timeout
(600000 ms) or in the background** — the Xcode build plus Apple's notarization
wait routinely takes 5–10 minutes.

## Before running — preconditions the script enforces or assumes

0. **Tests and the Release build happen here, and only here.** In a
   terminal the script asks "Run the unit tests before releasing? [Y/n]";
   Enter runs `scripts/test.sh` and aborts on any failure before bumping,
   building or publishing, `n` skips straight to the bump. Without a
   terminal (the way Claude runs it in the background) the tests run unless
   `--skip-tests` (or `RELEASE_SKIP_TESTS=1`) is passed; `--tests` forces
   them without asking. When the user asks to release without tests, pass
   `--skip-tests`; otherwise run with tests. There is no commit-time or
   push-time test gate. Do not run `scripts/test.sh`, `xcodebuild … test`,
   or a Release build after ordinary changes — a `build-for-testing`
   compile check is fine.
1. **Clean working tree** (the script refuses otherwise). Commit pending work
   first as its own feature commit(s) — never fold feature changes into the
   release commit. If there are uncommitted changes you didn't author this
   session, ask the user before committing them.
2. **Version intent.** The script auto-picks the version:
   - current `MARKETING_VERSION` not yet tagged on GitHub → releases it as-is;
   - already tagged → bumps the **last component** (1.1 → 1.2).
   For a different bump (e.g. 2.0), first edit `MARKETING_VERSION` (it appears
   **twice** in `Clip Builder.xcodeproj/project.pbxproj`) in the feature commit,
   then run the script. `CURRENT_PROJECT_VERSION` (build number) always +1s on
   its own — leave it alone.
3. Environment defaults are already correct for this machine (override only if
   they've changed): `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`,
   `NOTARY_PROFILE=ClipBuilderNotary`, Developer ID Application/Installer
   certificates in the keychain (team D7JTNCH58D), `gh` authenticated.
4. **Provisioning profiles.** `make_pkg.sh` embeds a Developer ID profile per
   channel ("ClipBuilder Developer ID", "Clip Builder Developer Beta ID",
   installed in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`)
   and signs the app with the shared keychain group. It fails when no
   installed profile matches the bundle id and the signing certificate; the
   fix is a new profile at developer.apple.com on the Aug 1 2026 Developer ID
   Application certificate, not skipping the entitlement.

The release does **not** capture Training Guide screenshots. When the guide's
UI changed, run `scripts/capture_help_screenshots.sh` by hand (Mac unlocked, no
other Clip Builder instance running) and commit the PNGs before releasing.

## After it finishes

1. Verify: `gh release view v<version>` — `ClipBuilder-Beta-<version>.pkg`
   attached, prerelease, tag correct; `gh release view` (latest) still shows
   the last stable.
   (The script already ran `stapler staple` and a Gatekeeper `spctl` check.)
2. **Replace the auto-generated notes with human ones.** Summarize what
   actually changed for a user of the app:
   ```bash
   git log --oneline v<prev>..v<version>   # raw material
   gh release edit v<version> --notes "..."
   ```
   Group as Features / Fixes; lead with the headline feature; skip internal
   refactors and CI noise.

## Blessing a release as stable (and naming it)

Every stable release gets a name, shown in the stable app's About box
("Version 1.152 “Harbor” (154)"). Blessing is a separate command, run when
the user says a release is good:

```bash
scripts/bless.sh <version> "<name>" --dry-run   # checks + plan, nothing published
scripts/bless.sh <version> "<name>"             # 5–10 min, background or long timeout
```

The user picks the name; never invent one. One to three words of letters,
digits and hyphens, never reused (`ReleaseNames.json`). The script needs a
clean main equal to origin, the tag published on GitHub, and an unlocked
screen (notarization). It builds the stable pkg from the tag in a throwaway
worktree with `ReleaseName.txt` added, checks the pkg payload, replaces the
release's `ClipBuilder-<version>.pkg`, retitles it "Clip Builder <version>
“<name>”", clears the prerelease flag, marks it latest unless a newer
stable exists, and commits "Bless <version> as stable" (ReleaseNames.json,
guide) on main and pushes. Releases before 1.152 cannot be named. If it
fails after the upload, finish the remaining `gh release edit` / commit steps
by hand rather than rerunning (a rerun rebuilds and re-notarizes).

## When it fails

- **Dirty tree** → commit/stash, rerun. **Tag already exists** → a previous run
  got partway; check `git tag`, `gh release list`, and resume manually with the
  remaining steps (push, `gh release create` / `gh release upload`).
- **Notarization rejected** → the script prints the `notarytool log` output;
  the classic cause is a stale build dir signed ad-hoc — `rm -rf build` and
  rerun. Check submission history with
  `xcrun notarytool history --keychain-profile ClipBuilderNotary`.
- **Partial publish** (commit+tag pushed but release creation failed) → do NOT
  rerun the whole script (it would bump again); finish with
  `gh release create v<version> dist/ClipBuilder-Beta-<version>.pkg --title "Clip Builder Beta <version>" --prerelease --generate-notes`.

## Never

- Never distribute the ad-hoc build from the `run-app` skill (`CODE_SIGN_IDENTITY=-`);
  releases must go through this pipeline.
- Never edit `CFBundleVersion`/`Info.plist` directly — versions live in the
  pbxproj build settings.
- Releases are pkg-only by decision (no DMG) — don't add one back.
