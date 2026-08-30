---
name: release
description: Publish a new Clip Builder release — bump the version, build + sign + notarize the pkg, refresh the Getting Started guide, tag, and create the GitHub release. Use when asked to release, ship, publish a version, or cut a release of this app.
---

# Release Clip Builder

One command does the whole pipeline — do NOT reimplement its steps by hand:

```bash
scripts/release.sh
```

It bumps versions in `project.pbxproj`, updates + re-renders the Getting Started
guide, builds/signs/notarizes/staples the pkg (`scripts/make_pkg.sh`), commits,
tags `v<version>`, pushes, and creates the GitHub release with the pkg + PDF
attached (`--generate-notes`). Run it from the repo root with a **long timeout
(600000 ms) or in the background** — the Xcode build plus Apple's notarization
wait routinely takes 5–10 minutes.

## Before running — preconditions the script enforces or assumes

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
4. Headless Chrome regenerates `docs/ClipBuilder-Getting-Started.pdf`; if
   Chrome is missing the script warns and the PDF must be regenerated manually
   before the release is complete.

## After it finishes

1. Verify: `gh release view v<version>` — pkg and PDF attached, tag correct.
   (The script already ran `stapler staple` and a Gatekeeper `spctl` check.)
2. **Replace the auto-generated notes with human ones.** Summarize what
   actually changed for a user of the app:
   ```bash
   git log --oneline v<prev>..v<version>   # raw material
   gh release edit v<version> --notes "..."
   ```
   Group as Features / Fixes; lead with the headline feature; skip internal
   refactors and CI noise.

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
  `gh release create v<version> dist/ClipBuilder-<version>.pkg docs/ClipBuilder-Getting-Started.pdf --title "Clip Builder <version>" --generate-notes`.

## Never

- Never distribute the ad-hoc build from the `run-app` skill (`CODE_SIGN_IDENTITY=-`);
  releases must go through this pipeline.
- Never edit `CFBundleVersion`/`Info.plist` directly — versions live in the
  pbxproj build settings.
- Releases are pkg-only by decision (no DMG) — don't add one back.
