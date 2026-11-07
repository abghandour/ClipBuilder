# Stable and Beta channels

Date: 2026-11-04. Status: in progress. Phase 0 and the code of phase 1 and 4 done 2026-11-04; the Xcode configurations, scheme and provisioning profiles, and phases 2, 3 and 5 are open.

## Goal

Ship Clip Builder as two apps that install and run side by side:

- **Clip Builder** (stable). Updates only to releases the developer has blessed.
- **Clip Builder Beta**. Updates to every release.

Both come from the same source and the same release pipeline. A release is
beta first; blessing it makes it the stable release too. No second repo, no
second branch, no second version scheme.

## How it works today

- `scripts/release.sh` bumps `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`,
  builds one notarized pkg through `scripts/make_pkg.sh`, commits, tags
  `v<version>`, pushes and creates a GitHub release with the pkg attached.
- The pkg installs `/Applications/Clip Builder.app` (bundle id
  `com.mokotti-solutions.clipbuilder`, pkg id
  `com.mokotti-solutions.clipbuilder.pkg`) plus the setup script under
  `/Library/Application Support/ClipBuilder/`.
- `Services/UpdateService.swift` asks GitHub for `/releases/latest` (which
  already excludes prereleases), compares versions numerically, downloads the
  first `.pkg` asset and hands it to Installer.app. `AppStore.checkForUpdates`
  runs it at launch and from the menu.
- Data lives in `~/Documents/ClipBuilder/` (profile JSON at the root,
  `data/` below it; `-ClipBuilderDataFolder` or the `ClipBuilderDataFolder`
  default overrides it). UserDefaults, caches and TCC grants are per bundle id.

## Design

### Channels

| | Stable | Beta |
| --- | --- | --- |
| App name | Clip Builder | Clip Builder Beta |
| Bundle id | `com.mokotti-solutions.clipbuilder` | `com.mokotti-solutions.clipbuilder.beta` |
| Install path | `/Applications/Clip Builder.app` | `/Applications/Clip Builder Beta.app` |
| Pkg id | `com.mokotti-solutions.clipbuilder.pkg` | `com.mokotti-solutions.clipbuilder.beta.pkg` |
| Pkg asset | `ClipBuilder-<version>.pkg` | `ClipBuilder-Beta-<version>.pkg` |
| Icon | AppIcon | `AppIcon-Beta`: the same icon under a blue "BETA" banner |
| Data folder | `~/Documents/ClipBuilder/` | the same folder |
| Library file | `profiles_db/<profile>.db` | `profiles_db/<profile>.beta.db` |
| Settings | `app_settings.json` | `app_settings.beta.json` |
| Update feed | newest release that is not a prerelease | newest release, prerelease or not |

Both apps share the version number of the commit they were built from. A
stable app on 1.146 that sees 1.150 blessed offers 1.150. The beta app offers
every release as it appears.

### Blessing

Every `release.sh` run publishes the GitHub release as a **prerelease** with
the beta pkg attached. That is the beta channel: GitHub's `latest` ignores
prereleases, so stable apps do not see it.

`scripts/bless.sh <version>` turns a release stable:

1. Checks out tag `v<version>` in a git worktree (the working tree may be
   dirty or ahead; the stable binary must come from the tagged commit).
2. Builds and notarizes the stable pkg from that worktree with `make_pkg.sh`
   in stable mode.
3. Uploads `ClipBuilder-<version>.pkg` to the same release.
4. Clears the prerelease flag (`gh release edit v<version> --prerelease=false`),
   which makes it GitHub's `latest`.
5. Updates the Getting Started guide's stable pkg name and commits
   "Bless <version> as stable" on main.

Unblessing is `gh release edit v<version> --prerelease=true`; stable apps
never downgrade, so the effect is only that the next bless wins. Blessing an
older release than the current stable is allowed but pointless for the same
reason.

A `release.sh --stable` option (optional, phase 3) does the bless in the same
run for the case where the release is known good already.

Why build the stable pkg at bless time rather than at every release: a
release today is a 5 to 10 minute notarization, releases happen several times
a day, blessing happens rarely. The two binaries are built from the same
commit; the only difference is the channel build setting.

### Data

Both apps use the one data folder, `~/Documents/ClipBuilder/`, and differ
only in the files they own:

- The beta opens `profiles_db/<profile>.beta.db` beside the stable
  `<profile>.db`. Two SQLite files, not two sets of tables: every query in
  the `Database+<TableGroup>` extensions names its table, `PRAGMA
  user_version` is per file, and one file would make the two apps share a
  write lock and a corruption. The beta's library is imported from the
  stable one on first launch, automatically (see First launch below).
- The beta writes `app_settings.beta.json`, imported from the stable file on
  first launch. Synthesized `Codable` encoding drops keys an older app does
  not know, so a stable app saving a shared settings file would erase
  beta-only fields; a separate file avoids that. Profile JSON at the root
  (brand settings, Express presets, the team `profile_id`) stays shared:
  both apps must bind to the same team profile, and a beta-only key lost to
  a stable save is a cosmetic regression, not data loss. The same rule the
  sync layer needs (below) applies here: a save should keep keys it did not
  decode, which `BrandProfile` can do by round-tripping unknown keys.
- Everything else is shared on purpose: source footage, scene and frame
  caches (content keyed), `assets/`, `learned/`, exports, logs under their
  own name (`logs/beta/`).

#### First launch: nothing to reconfigure

The beta must open looking exactly like the stable app did a second ago.
The import is automatic, not offered: when the beta starts and finds no
`app_settings.beta.json`, it imports without asking, shows progress if the
libraries are large, and ends with a one-time banner "Imported your settings
and library from Clip Builder <version>". What it imports:

1. **Every profile's library.** `profiles_db/<profile>.db` to
   `<profile>.beta.db` for every profile JSON in the folder, not only the
   active one, through SQLite's online backup (`VACUUM INTO` or
   `sqlite3_backup`) rather than a file copy: the stable app may be running
   with the file open in WAL mode, and a backup gives a consistent snapshot
   with the WAL folded in. The beta then runs its own migration on the copy.
   A profile the stable app creates later has no beta file; the beta imports
   it the first time that profile is opened, by the same path.
2. **Settings.** `app_settings.json` to `app_settings.beta.json`.
   `active_profile.json`, `analysis_prompts.json`, `builder_state/`,
   `taste/`, `assets/`, `learned/` and the profile JSON are shared, so
   nothing to import.
3. **User defaults.** The beta reads the stable app's defaults domain
   (`UserDefaults(suiteName: "com.mokotti-solutions.clipbuilder")`, readable
   because the app is not sandboxed) and copies every key into its own:
   window frames, the data folder override, per-screen choices such as the
   step kind, kept lists, dismissed banners.
4. **Keychain.** Signed builds use the data-protection keychain, where an
   item belongs to the app that wrote it; the beta's bundle id cannot read
   the stable app's team session, Google Drive tokens, ElevenLabs key or
   Instagram tokens (AI provider keys live in the settings file and come
   with it). Both apps therefore adopt one shared keychain access group
   (`<team id>.com.mokotti-solutions.clipbuilder.shared`) and the four
   keychain stores read and write in it through one `AppKeychain.Item`; an
   item found only in the login keychain is adopted by the group on first
   read. **This ships in a stable release before the first beta**, or the
   beta would still ask for every key once. With the group in place nothing
   is copied: both apps see the same items, and a key changed in one is
   changed in the other.

   Measured 2026-11-04 with a signed probe: `keychain-access-groups` is a
   restricted entitlement on macOS. A binary that carries it without an
   embedded provisioning profile is killed at launch (exit 137), ad-hoc or
   Developer ID signed alike, and `com.apple.application-identifier` alone
   still gets -34018 from the data-protection keychain. So the entitlement
   (`ClipBuilder/Clip Builder.entitlements`) is applied only by
   `make_pkg.sh` (`CODE_SIGN_ENTITLEMENTS` plus
   `PROVISIONING_PROFILE_SPECIFIER` in its signing arguments), never by the
   Xcode Debug configurations, whose ad-hoc builds keep the login-keychain
   fallback. Needed once from the developer portal: explicit App IDs for
   `com.mokotti-solutions.clipbuilder` and `.beta` with Keychain Sharing on
   the shared group, and a Developer ID (Mac) provisioning profile for
   each, installed on the build Mac. The profiles embed as
   `embedded.provisionprofile`; notarization accepts them.
5. **Not importable.** TCC grants: the beta asks for Documents access (and
   Automation for the dub shortcuts) once on first use. Nothing else.

A re-import is available from Settings › Advanced, "Replace this library
with the stable one", confirmed, for when the stable library has moved on
and the tester wants to start over from it.

Promoting a beta library to stable is a file copy over `<profile>.db`,
allowed once the stable app's `schemaVersion` is at least the beta file's
stamp: bless the beta, update stable, copy. The copy sheet checks the stamp
and says so instead of failing later. The reverse (stable into beta) is the
first-launch import and is always allowed, since the beta is never older.

The existing data folder setting and `-ClipBuilderDataFolder` keep working
for both apps; nothing lets the beta open the stable file by accident, the
file name is derived from the channel.

Shared on purpose beyond the folder:

- Keychain items (team session, Drive and Instagram tokens, ElevenLabs
  key): one shared keychain access group, see First launch.
- The Siri dub shortcuts ("Clip Builder Dub <Name>"): run by name, no change.
- `/Library/Application Support/ClipBuilder/` setup script and the ffmpeg and
  yt-dlp installs: same dependencies, either pkg may refresh the script.

Separate automatically: UserDefaults (seeded from stable on first launch,
then independent), `~/Library/Caches`, TCC grants (the beta asks for
Documents access once), Launch Services registration.

### Team sync

Sync state lives in the library file: `sync_binding`, the per-table
cursors, `sync_outbox`, `sync_id` columns and the triggers. The beta's
library is a copy of the stable one, so it comes bound to the same team and
profile and keeps syncing. From the server's point of view the beta is a
second member on the same Mac under the same account, and every rule the
Team Sync plan already has applies between the two apps:

- Rows the beta creates or edits in synced tables reach the stable library
  through the server, and the other way round. Team sync is therefore the
  bridge between the two libraries for everything in `SyncTable`: footage
  rows by fingerprint, analysis, scenes, transcripts, picks, people,
  lessons, Instagram data, the brand document. Nothing to promote there.
- Tables outside the sync list (renders in `generated_videos`, jobs,
  caches, local paths) stay per library and move only by the promotion
  copy.
- The same row edited in both apps: last write wins by server time;
  timelines get the "(member's copy)" rule instead of a merge. With one
  person this means "the app you saved in last wins", which is what a
  tester expects.
- A library copied with a non-empty outbox pushes those changes twice, once
  from each app; the server upserts by `sync_id`, so that is harmless.
- `updated_by` is the account, not the device, so history does not tell the
  two apps apart. Acceptable; a `channel` note in `updated_by` metadata is
  optional polish.

Schema changes on the server follow the same expand-then-contract rule as
the library (rules 1 to 3 below) and keep the existing order: the Supabase
migration goes in before the beta that adds the column is released, as
today. While that beta is unblessed the stable app keeps pushing rows
without the new column, which an additive migration tolerates (PostgREST
leaves absent columns alone on upsert), and pulls rows with it, which the
client ignores. Dropping or renaming a server column waits until stable is
past the expand step.

One client change belongs in phase 1: `TeamProfileDocument.apply` writes
every key in its own list from the pulled document, so a document pushed by
the stable app, which omits keys it does not know, would null out the beta's
values for those keys. Applying only the keys present in the pulled
document keeps a beta-only brand setting on the beta until stable learns it.
The `sync_profile_adoption` guards that already exist per key stay.

Sign-in: the team session is a Keychain item under the service
`com.mokotti-solutions.clipbuilder.team-sync`; with the shared keychain
access group (First launch, item 4) both apps use the same session.

### Database schema changes

`Database.init` runs the `CREATE … IF NOT EXISTS` schema script, then runs
`migrate` whenever `PRAGMA user_version` **differs** from `schemaVersion`,
and stamps `schemaVersion` afterwards. The steps are mostly idempotent
(column probes before `ALTER TABLE ADD COLUMN`) but some rebuild tables
(`transcript_backups`, `voice_profiles`, `scenes`). With two apps that can
differ by several schema versions, three rules keep the data safe:

1. **Never open a newer library with an older app.** Today a stable app at
   version 44 opening a library the beta stamped 45 would see `45 != 44`,
   re-run every migration step, and stamp the library back **down** to 44;
   the beta would then re-run them again. Phase 1 changes the gate to
   direction-aware: `stamped > schemaVersion` refuses to open the profile
   with "This library was last opened by Clip Builder Beta <version>. Update
   Clip Builder, or open it with the beta." The stamp is never lowered. This
   is the one code change the shared-folder option depends on, and it is
   worth shipping in the stable app before the first beta exists, so the
   stable build in the wild already refuses rather than downgrades.
2. **Back up before a version bump.** When `stamped < schemaVersion` and the
   library is not empty, copy `<profile>.db` to
   `data/db-backups/<profile> <date> before-v<schemaVersion>.db` before
   `migrate` runs (the folder already exists for manual backups). Going back
   to stable after trying a beta on a shared folder is then a file copy.
3. **Expand, then contract.** While a beta is unblessed its migrations must
   be additive: new tables, nullable or defaulted columns, new indexes. The
   stable app reads rows with `SELECT *` into named fields and ignores
   columns it does not know, and inserts without the new columns, so
   additive changes are safe for a stable app that shares the library
   through a sync or a copy. Renames, drops and table rebuilds ship only in
   a release that the developer intends to bless, and only once every stable
   user can have updated past the expand step. `Codable` settings and record
   JSON already follow this rule (new stored properties are Optional).

With per-channel library files rule 1 matters for the promotion copy and
for a library file moved by hand; rules 2 and 3 matter for every release
because team sync and copies move data between the apps anyway.

Team sync: a column added to a `SyncTable` is pushed on every sync, and
PostgREST rejects the whole table's push until the Supabase column exists,
so the server migration goes in before the beta that adds the column is
released, as today. Server changes stay additive for the same reason the
library's do: stable apps keep pushing the old shape.

### In the app

- `AppChannel` (`Services/AppChannel.swift`): `.stable` or `.beta`, read once
  from an Info.plist key `ClipBuilderChannel` that the build configuration
  sets. Exposes the display name, the pkg asset suffix, the default data root
  and the update feed.
- `UpdateService` takes the channel: stable keeps `/releases/latest`; beta
  reads `/releases?per_page=5` and takes the newest non-draft release. Both
  pick the pkg asset by the channel's suffix and ignore the other channel's
  pkg. A blessed release carries both assets; an unblessed one carries only
  the beta pkg, so a stable app that somehow sees it reports "no installer
  package" as it does today.
- Window title and About show "Clip Builder Beta <version>"; the update alert
  names the channel. The beta's Help menu gets "Download the stable app"; the
  stable's gets "Try the beta" (both open the releases page).
- **The beta is unmistakable** (decided 2026-11-04). Two marks, both in one
  saturated blue (`Theme.projectTint`, `Color.blue`), chosen because
  nothing else in the chrome is that blue:
  - **Icon.** `AppIcon-Beta` is the stable icon with a blue diagonal banner
    across the lower right corner reading BETA in white, heavy, uppercase,
    sized to stay legible at 32 pt in the Dock and in Finder lists (the
    banner is about a third of the icon's width; at 16 pt it degrades to a
    plain blue corner). Generated once by a script from the 1024 pt master
    (`scripts/make_beta_icon.sh`, ImageMagick or a small Swift tool) so the
    two icon sets never drift; the output set is committed.
  - **Toolbar.** A blue capsule reading BETA, white bold text, sits in the
    window's title bar as a toolbar item on the leading edge, next to the
    title and subtitle that `ScreenTitle` sets (Views/Theme.swift). It is
    present on every screen and every window the app opens (the Builder,
    sheets with their own toolbar), not only the main window. It does not
    wrap or truncate (`lineLimit(1)` plus `fixedSize`, per the toolbar
    rule). Clicking it opens a popover: the version and build, "Updates to
    every release", "Download the stable app". The stable app has no mark
    at all; absence is the stable signal.
  - The beta's status bar at the bottom of the window takes the same blue
    as its leading edge tint, so a screenshot cropped to the content still
    tells the channel.
- Nothing else in the app branches on the channel. Features do not gate on
  it; the beta is simply newer.

### Xcode

- Two new build configurations, `Debug-Beta` and `Release-Beta`, based on
  `Configuration/Beta.xcconfig` (written): `PRODUCT_NAME`,
  `PRODUCT_MODULE_NAME = Clip_Builder` (so the module and `@testable
  import` stay the same), `PRODUCT_BUNDLE_IDENTIFIER`,
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon-Beta`,
  `INFOPLIST_KEY_CFBundleDisplayName` and `CLIPBUILDER_CHANNEL = beta`.
  Custom keys cannot go through `INFOPLIST_KEY_*` (only Apple's known keys
  are honoured). The target's Info.plist already comes from
  `Configuration/GoogleDrive.xcconfig` (`GoogleDrive-Info.plist`, or the
  ignored `GoogleDrive-Local.plist` on the release Mac), so
  `GoogleDrive-Info.plist` carries `ClipBuilderChannel =
  $(CLIPBUILDER_CHANNEL)` and `Beta.xcconfig` includes
  `GoogleDrive.xcconfig`. Because the local plist does not carry the key,
  `AppChannel` falls back to the bundle id (`….beta` is beta), so the
  channel is right whichever plist a build uses. Merged into main
  2026-11-06; the stray `ClipBuilder/Info.plist` was dropped (it was copied
  as a resource, not used as the Info.plist).
  Verified 2026-11-04 by building the stable scheme with those settings
  overridden on the command line: the beta app launched against a folder
  holding stable settings and two libraries, imported all of them, and
  showed the capsule, title, status bar edge and welcome notice.
- A second scheme `MyApp Beta` that builds those configurations. The test
  target stays on the stable configurations; `scripts/test.sh` is unchanged.
- `make_pkg.sh` reads `CHANNEL` (`stable` default, `beta`) and derives the
  configuration, app name, pkg id, pkg file name, installer title and the
  postinstall's app path from it. `distribution.xml` and `postinstall` take
  the name and id as substitutions like `__VERSION__` today.

`scripts/release.sh`, `scripts/make_pkg.sh` and `project.pbxproj` are on the
do-not-touch list for the agents; the changes above are proposed here and
made by, or explicitly approved by, the developer.

## Phases

### Phase 0. Ship in stable first

Two changes the stable app in the wild needs before the first beta exists,
released as an ordinary stable release:

- The shared keychain access group, with the four stores moving their
  existing items into it on first read (code done 2026-11-04:
  `Services/AppKeychain.swift`, the entitlements file; the provisioning
  profiles and the `make_pkg.sh` signing arguments are the developer's).
- The direction-aware database gate and the pre-migration backup (done
  2026-11-04: `Database.NewerLibrary`, `db-backups/<profile> <date>
  before-v<N>.db` by `VACUUM INTO`, for libraries under `profiles_db`).

### Phase 1. Two apps from one tree

Code done 2026-11-04 (`Services/AppChannel.swift`,
`Services/ChannelImport.swift`, `App/AppStore+Channel.swift`,
`Views/BetaBadge.swift`, `scripts/make_beta_icon.swift` and the generated
`AppIcon-Beta` set, `Configuration/Beta.xcconfig`, the `ClipBuilderChannel` key in `Configuration/GoogleDrive-Info.plist`,
tests under `ClipBuilderTests/Services/Channels/`). Open: the
configurations and the scheme in the project file.

- `AppChannel`, the plist key, `Beta.xcconfig`, the configurations, the
  scheme, the generated `AppIcon-Beta` set, the toolbar capsule with its
  popover and the status bar edge, the window title and About text, the beta's
  library and settings file names, the automatic first-launch import
  (libraries by online backup, settings, user defaults), the per-profile
  lazy import, the re-import command, the promotion copy with its stamp
  check.
- Tests: `AppChannelTests` (plist values, defaults for a missing key),
  data root per channel; `DatabaseTests` for the newer-stamp refusal, the
  unchanged stamp, and the backup file.
- Verify: build both schemes, launch the beta while the stable app is
  running on the one folder; the beta opens on the same profile, screen,
  window frame, settings, team sign-in and provider keys with no prompt
  but the Documents access one; a profile created in stable afterwards
  imports when first opened in the beta; the stable app is unchanged; a
  promotion copy is refused while the beta file is newer.

### Phase 2. Two packages

- `make_pkg.sh` channel mode, installer template substitutions, the
  `Clip Builder Setup.command` app path, `CHANNEL=beta make_pkg.sh` producing
  `dist/ClipBuilder-Beta-<version>.pkg`.
- Verify: install both pkgs on this Mac, both apps present in
  `/Applications`, receipts under their own ids (`pkgutil --pkgs`), the
  setup script still runs, uninstalling one leaves the other.

### Phase 3. Release and bless

- `release.sh`: builds the beta pkg, `gh release create --prerelease`, asset
  name with the `-Beta` suffix, the guide no longer updated here.
- `scripts/bless.sh <version>` as designed; the optional `release.sh --stable`.
- `.claude/skills/release` describes both commands; a `bless` skill or a
  section in the release skill.
- Verify: release a beta, confirm GitHub shows it as a prerelease and
  `/releases/latest` still returns the previous stable; bless it, confirm the
  stable pkg is attached and `latest` moves.

### Phase 4. Channel-aware updater

Code and tests done 2026-11-04 (`UpdateService.update(from:channel:currentVersion:)`,
`UpdateServiceTests`); the live check waits for the first prerelease.

- `UpdateService` with the channel feed and asset suffix; `AppStore`
  messages; the Help menu links.
- Tests: `UpdateServiceTests` over fixture JSON (prerelease skipped for
  stable and taken for beta, asset chosen by suffix, missing asset error,
  version compare), using an injected fetch so no network runs.
- Verify live: an old stable build against a blessed release updates to the
  stable pkg; an old beta build against an unblessed release updates to the
  beta pkg; a stable build against an unblessed newer release stays put.

### Phase 5. Documentation

- Getting Started guide: two download sections and what "beta" means.
- `CLAUDE.md` map and the release skill: channels, bless, the two schemes.
- First stable bless of the new pipeline: the stable app in the wild (1.149)
  must still find its update, so the first blessed release has to carry a
  pkg named `ClipBuilder-<version>.pkg` (it does) and stay under
  `/releases/latest` (it does).

## Open decisions

None.

Decided 2026-11-04: the stable pkg is built at bless time, from the tagged
commit in a worktree, not at every release.

Decided 2026-11-04: one data folder with per-channel library and settings
files (not a separate root, not separate tables in one file). The beta
carries a prominent blue BETA banner on its icon and a blue BETA capsule in
every window's toolbar, plus a blue status bar edge.

## Out of scope

- Delta or in-place updates (Sparkle). The pkg hand-off stays.
- A third channel or per-user rollout.
- Changing version numbering.
