# Profile Editing Defaults Sync Plan

Date: October 9, 2026. Status: implemented October 9, 2026 (Codex), uncommitted. Verified: Debug build clean; SettingsCodableTests, SyncMappingTests, TeamSyncCoordinatorTests, SyncEngineTests 100/100 including the nine new tests. Not yet exercised by hand in the app.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).

## Problem

`app_settings.json` mixes two kinds of state. Most of it is about this Mac:
Supabase endpoint, Instagram app credentials and cookies, AI provider
binaries and models, on-device agreement scores, builder agent limits, theme.
That stays local; the Team Sync plan lists `app_settings.json` as never
synced and that holds for the file.

A smaller part is brand policy that only landed in app settings because the
profile had no home for it: crossfade length, transition SFX, beat snap, the
podcast dead-air and filler thresholds, highlight scoring, the cleanup cut
policy, auto-translate language, the transcription language and vocabulary
hint, and the visual/speech analysis mode. Two members editing the same brand
should get the same cuts and the same renders. Today each Mac has its own
copy and nobody notices until the renders differ.

Four fields that already live in `BrandProfile` were also left out of the
synced profile document: `default_render_settings`, `buzz_sources`,
`buzz_extra_sources` and `mini_instructions`. They are brand policy too.

## Decision

Move the creative defaults into `BrandProfile` as one optional nested
document, `editing`, and add it to the synced profile document. Do not sync
`app_settings.json` as a document and do not add a Supabase table. The
profile document already has per-field merge, tombstone handling, and
unknown-key preservation for older clients, so no server migration and no
"needs update" bump.

What moves (app settings key, new home):

| Today | New |
| --- | --- |
| `transitions.xfade_duration`, `sfx_enabled`, `beat_snap` | `editing.transitions.*` |
| `podcast.dead_air_seconds`, `filler_run_seconds`, `cleanup_cut_policy`, `auto_translate_language`, `highlight_threshold`, `highlight_max_seconds`, `speaker_hold_seconds` | `editing.podcast.*` |
| `analysis_mode`, `whisper_language`, `transcribe_hint` | `editing.footage.analysis_mode`, `language`, `vocabulary_hint` |

What stays in app settings: `podcast.review_cuts_by_default` (a workflow
preference, not policy), `transcribe_provider`, `transcribe_model`, and
everything else in the file. `AppSettings` keeps the moved fields in its
Codable shape for one release so an older build reading the same file does
not lose them; nothing in the app reads them any more.

Added to the synced key set without moving: `default_render_settings`,
`buzz_sources`, `buzz_extra_sources`, `mini_instructions`.

Stays out of the document: `logo_path`, `source_folder`, `output_folder`,
`taste_exemplar_frames`, `instagram_publish_account`, `learned_sharing`,
`team_sync_paused`, provenance records. Same reasons as phase 1: machine
paths or tied to a member's token.

## Types

In `Data/BrandProfile.swift` (or a new `Data/ProfileEditingDefaults.swift`):

```swift
nonisolated struct ProfileEditingDefaults: Codable, Sendable, Equatable {
    var transitions = TransitionSettings()        // existing struct, reused
    var podcast = PodcastEditingPolicy()
    var footage = FootageDefaults()
}

nonisolated struct PodcastEditingPolicy: Codable, Sendable, Equatable {
    var deadAirSeconds = 1.5
    var fillerRunSeconds = 2.0
    var highlightThreshold = 7.0
    var highlightMaxSeconds = 30.0      // keep the clamp PodcastSettings has
    var speakerHoldSeconds = 1.5
    var cleanupCutPolicy = CleanupCutPolicy.acceptDeadAir
    var autoTranslateLanguage = ""
}

nonisolated struct FootageDefaults: Codable, Sendable, Equatable {
    var analysisMode = "visual"         // visual | speech
    var language = ""                   // empty = auto
    var vocabularyHint = ""
}
```

`BrandProfile.editing: ProfileEditingDefaults?` with coding key `editing`.
Optional so every existing profile JSON still decodes (codebase rule). All
three nested structs use snake_case coding keys and `decodeIfPresent` with
defaults, matching the existing settings structs, so a document written by a
newer build with extra fields decodes on an older one.

`PodcastSettings` and `TransitionSettings` keep their current shape.
`PodcastEditingPolicy` gets an `init(_ settings: PodcastSettings)` and
`FootageDefaults` an `init(_ settings: AppSettings)` for seeding.

## Reading the values

One accessor on `AppStore`:

```swift
var editingDefaults: ProfileEditingDefaults {
    activeProfile.editing ?? ProfileEditingDefaults(seedingFrom: settings)
}
```

Every read site switches to it. Known sites (from grep on October 9):
`AppStore+AITools`, `AppStore+Analysis`, `AppStore+Jobs`,
`AppStore+MiniWizard`, `AppStore+Wizard`, `AppStore+WizardPipeline`,
`AppStore.swift`, `Services/Script/BuilderWizardLibrary.swift`,
`Views/AutoTranslationRunner.swift`, `Views/Builder/WizardSheetModel.swift`,
`Views/DispatchPlanSheet.swift`, `Views/WizardView.swift`, `Views/SettingsView.swift`.
Services that take a `PodcastSettings` or `TransitionSettings` value as a
parameter keep taking it; the call site builds it from `editingDefaults`.
Grep again before finishing; the list above is a starting point, not a
contract.

The fallback means a profile that has never been edited behaves exactly as
today on every Mac. Nothing changes until a value is written.

## Writing and seeding

- Settings controls write to `store.activeProfile.editing` (seed from the
  accessor on first write, then set the field), and call `saveProfile()`
  like the other profile controls. `saveProfile` already queues the synced
  document when the profile has a team.
- Seeding without a user edit happens in exactly one place, `saveProfile`,
  under this rule: `editing == nil` and either `teamID == nil`, or the
  initial sync has completed and the synced document on disk has no
  `editing` key. The second condition keeps an upgrading second Mac from
  pushing its own local values over what the team already has. Do not seed
  from the accessor, at load, or in `saveSyncProfile`.
- The analysis-mode guard in `SettingsView.onAppear` (speech reset to visual)
  moves with the field: apply it to the profile value, and only write if it
  changes.

## Sync

- Add `"editing"`, `"default_render_settings"`, `"buzz_sources"`,
  `"buzz_extra_sources"`, `"mini_instructions"` to `TeamProfileDocument.keys`.
  `encode` and `applying` need no other change; `merging` already recurses
  into objects, so two members editing different podcast thresholds in one
  cycle both land.
- Adoption: the baseline captured by `beginSyncProfileAdoption` is the
  encoded document, so a document without `editing` and a local profile
  without `editing` compare equal and the remote value is adopted. Verify
  with a test rather than by reading.
- 1.96 clients ignore the new keys on apply and preserve them on save
  (`saveSyncProfile` copies unknown keys forward). No `schemaVersion`
  change, no SQLite migration, no Supabase migration.

## UI

Keep the General tab layout; the Analysis, Transcription, Podcast
highlights and Transitions sections stay where they are. Each of those
sections gets a one-line footer, "Per profile. Shared with the team when the
profile has one," and the Transcription section keeps provider and model
bound to app settings with no footer. Bind the controls to the profile
through a small binding helper that seeds on first write. If the General
tab's grouped `Form` makes mixing the two sources awkward, moving the
sections to the Profile tab is acceptable; do not add a new tab.

## Tests

- `SettingsCodableTests`: `BrandProfile` with and without `editing` decodes;
  `ProfileEditingDefaults` round-trips with snake_case keys; a document with
  an unknown nested field decodes.
- `SyncMappingTests`: `TeamProfileDocument.encode` includes `editing` and
  the four added keys and still excludes paths; `applying` sets `editing`
  on a receiver that had none; `merging` with remote `editing.podcast`
  edits and local `editing.transitions` edits keeps both.
- `TeamSyncCoordinatorTests` or `SyncEngineTests`: the seeding rule. A team
  profile with `editing == nil` whose synced document already carries
  `editing` is not seeded on save; one whose document lacks it is.
- A unit test that `AppStore.editingDefaults` falls back to app settings
  when the profile has no `editing`.

## Phases

1. Types, accessor, read-site migration, seeding rule, keys in
   `TeamProfileDocument`, tests. One commit.
2. Settings UI rebinding and footers. One commit.

Both ship together in the next release; phase 1 alone changes no behaviour
for a user who never edits, so it is safe to land first.

## Out of scope

- AI task routing as a team recommendation with local override. Later, if
  wanted.
- Syncing the logo image or exemplar frames as assets.
- Removing the moved fields from `AppSettings` Codable shape (one release
  later).
