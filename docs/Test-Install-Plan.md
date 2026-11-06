# Test Install Plan

Date: 2026-11-06. Status: proposed, not implemented. A trial implementation was reverted on
2026-11-06; the notes below record what it learned.

Two Clip Builder installs on one Mac: the stable release and a test build,
side by side, without the test build touching the stable app's data.

## Decisions (user, 2026-11-06)

- The test install works on a copy of the stable data, refreshed on demand.
- Sign-ins are shared: the Keychain service names stay as they are, so Team
  Sync, Instagram, Google Drive and ElevenLabs sign-ins carry over.

## Shape

| | Stable | Test |
| --- | --- | --- |
| App | `/Applications/Clip Builder.app` (notarized pkg, `scripts/release.sh`) | `/Applications/Clip Builder Test.app` (`scripts/install-test.sh`) |
| Bundle id | `com.mokotti-solutions.clipbuilder` | `com.mokotti-solutions.clipbuilder.test` |
| Data | `~/Documents/ClipBuilder` | `~/Documents/ClipBuilder Test` |
| Settings (UserDefaults) | its own domain | its own domain, copied from stable on refresh |
| Keychain | shared | shared |

## Phases

1. **Data root follows the install.** `AppInstall` (Data/AppInstall.swift)
   says whether this is the test build (bundle id ends in `.test`) and names
   the data root (`ClipBuilder` or `ClipBuilder Test`). `ProfileStore` and a
   new profile's Input/Output defaults use it instead of the literal
   `~/Documents/ClipBuilder`. The window title says "Clip Builder Test".
2. **`scripts/install-test.sh`.** A normal Release build into `build-test`
   (command-line PRODUCT_NAME / bundle id overrides also hit the Swift
   package targets and fail the build), then a copy renamed
   `Clip Builder Test.app` with CFBundleIdentifier / CFBundleName /
   CFBundleDisplayName set by PlistBuddy and re-signed ad-hoc. It quits a
   running Test app and replaces `/Applications/Clip Builder Test.app`.
3. **`scripts/refresh-test-data.sh`.** Quits the Test app, replaces
   `~/Documents/ClipBuilder Test` with an APFS clone of `~/Documents/ClipBuilder`
   (copy-on-write, no extra space for the videos), snapshots each SQLite
   database with `.backup` so a running stable app's WAL is included,
   rewrites every stored path under the stable root to the test root (all
   TEXT columns in every database, profile JSON and data JSON), and copies
   the stable settings domain into the test one without the data-folder
   override.

## Known limits

- Shared sign-ins mean a Team Sync from the Test app pushes test edits to
  the team as you. Sync is manual only, so it happens only when pressed.
- The Test app is ad-hoc signed: macOS asks once per rebuild before it
  reads Keychain items the stable app created, and asks for Documents
  access on first launch.
- Do not touch `scripts/release.sh` or `scripts/make_pkg.sh`; the stable
  path is unchanged.
