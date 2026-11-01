# Highlight history and shared Express picks

Date: November 1, 2026. Status: implemented November 1, 2026, Codex-reviewed; server migration not yet pushed. Requested by the user
on November 1, 2026.

## What the user asked for

Every highlight the AI wizard generates (Express flows and the full AI
Wizard) is saved with all the settings used to generate it and who generated
it, so teammates see it. A history selector lets the user navigate between
previous highlights and reopen or re-render one. The Express custom
selections (transcript picks, Q&A kept exchanges, fight-metric picks) are
saved and shared too, one set per source video per project. Projects sync so
the history has a home on every Mac. What syncs is the plan, settings and
author, not the rendered file.

## Decisions

- One new table `wizard_highlights`, one row per generated take (Express
  candidate or regenerate) or rendered reel (Express render, full wizard
  automatic reel, accepted selection render). Not the rendered MP4.
- Cross-Mac footage identity is by video hash plus source time, never local
  scene or video ids (`WizardSelectionRules.snapshot` already does this for
  Mini P2). Every history row stores a `footage_json` snapshot and
  `video_hashes_json`; `plan_json` keeps the local plan for the Mac that made
  it. Opening a teammate's row resolves scenes by hash and time, creating a
  scene when none matches (like `Database.storyScene`).
- Author = Team Sync signed-in email when attached, else `NSFullUserName()`.
- Express picks gain a nullable `project_id`; reads are scoped to the current
  project, legacy NULL rows are adopted into the current project on first
  write. Q&A kept exchanges move from UserDefaults into a `qa_picks` table
  (UserDefaults value imported once per video when the table is empty).
- Sync identity: `wizard_highlights`, `transcript_picks`, `fight_picks` use
  random sync ids (created on one Mac, updated by id). `projects` natural key
  `[name, created_at]`; `project_videos` `[project_id, video_id]`; `qa_picks`
  `[project_id, video_id, scene_id]`.
- Server schema version 8. Migration file written in the repo; `supabase db
  push` is run only when the user says so, and the client ships with it.

## Phase 1: local storage and capture

- `Data/Database.swift`: tables
  - `wizard_highlights(id INTEGER PK, project_id INTEGER NOT NULL REFERENCES
    projects ON DELETE CASCADE, flow TEXT NOT NULL, batch_id TEXT, parent_id
    INTEGER REFERENCES wizard_highlights ON DELETE SET NULL, selection_id
    INTEGER REFERENCES wizard_selections ON DELETE SET NULL, take_id INTEGER
    REFERENCES wizard_selection_takes ON DELETE SET NULL, generated_video_id
    INTEGER REFERENCES generated_videos ON DELETE SET NULL, video_hashes_json
    TEXT NOT NULL DEFAULT '[]', footage_json TEXT NOT NULL DEFAULT '[]',
    settings_json TEXT NOT NULL DEFAULT '{}', plan_json TEXT, provenance_json
    TEXT, note TEXT, author TEXT, created_at TEXT DEFAULT (datetime('now')))`
    with an index on `(project_id, created_at)`.
  - `qa_picks(id INTEGER PK, project_id INTEGER NOT NULL REFERENCES projects
    ON DELETE CASCADE, video_id INTEGER NOT NULL REFERENCES videos ON DELETE
    CASCADE, scene_id INTEGER NOT NULL REFERENCES scenes ON DELETE CASCADE,
    position INTEGER NOT NULL DEFAULT 0, created_at TEXT DEFAULT
    (datetime('now')), UNIQUE(project_id, video_id, scene_id))`.
  - `transcript_picks.project_id INTEGER` and `fight_picks.project_id
    INTEGER` (nullable, migration via `columnNames`), schema version bump.
- `Data/WizardHighlight.swift` (new): `struct WizardHighlightRecord:
  Identifiable, Codable, Sendable, Hashable` mirroring the columns, plus
  `enum WizardHighlightFlow: String` (`expressHighlights`, `expressQA`,
  `expressTranscript`, `expressFight`, `fullAutomatic`, `fullSelection`) and
  `struct WizardHighlightSettings: Codable, Sendable` = `{ options:
  WizardOptions, mini: MiniWizardSettings?, length: String?, outputMode:
  String?, picks: [PickSnapshot]?, qaKept: [FootageRef]?, aiSnapshot:
  AISettingsEnvelope? }` where `FootageRef { videoHash, start, end }` and
  `PickSnapshot { kind, videoHash, start, end, position, eventTimes }`.
  All Optional except `options`.
- `Services/Wizard/HighlightFootage.swift` (new, nonisolated): `snapshot(plan:
  scenes:videos:) -> [FootageRef]` and `resolve(refs:, localVideos:,
  scenes:) -> [Int64: ResolvedScene]` (match by hash then by range within
  0.05 s), used on open.
- `Data/Database+WizardHighlights.swift` (new): insert, update
  (generated_video_id, take_id), `fetchHighlights(projectID:videoHash:)`,
  `fetchHighlight(id:)`, delete; qa_picks CRUD; picks fetch/write scoped by
  project with legacy adoption.
- `App/AppStore+HighlightHistory.swift` (new): `currentAuthor`,
  `recordHighlight(...)` helpers called from the capture points:
  - Express candidates: end of `generateMiniFootage` (one row per candidate,
    flow by footage kind) and `regenerateMiniCandidate` (with `parent_id`).
  - Express render: `generateMiniVideos` after the chosen takes are known
    (one row per rendered reel, `generated_video_id` filled after render).
  - Full wizard: `runWizard` automatic reels (after `generated_videos`
    rows exist, one row per reel with `WizardRunSettings`), and
    `renderWizardSelection` (one row per rendered selection).
- Picks: `AppStore+MiniTranscript`, `AppStore+MiniFight`, and the Q&A kept
  path read and write through the project-scoped functions; `MiniWizardMemory
  .qaKept` becomes the one-time import source.
- Tests: `WizardHighlightRecord` JSON round trip with missing keys;
  `HighlightFootage` snapshot/resolve (hash match, range tolerance, missing
  video); `DatabaseTests` additions for highlights, qa_picks, and project-
  scoped picks with legacy adoption.

## Phase 2: history selector and navigation

- `Views/HighlightHistoryBar.swift` (new): a compact bar with a Previous
  button, a Menu listing entries (newest first: "<date> · <author> · <flow>
  · <length or recipe> · <note excerpt>", current entry checked), a Next
  button, and an Open button. Text is `lineLimit(1)` + `fixedSize`.
- Express: shown in the Footage card header of `MiniWizardView` for the
  current project and source video. Choosing an entry loads its plan as the
  run's candidates (resolving footage by hash) and its `mini` settings into
  the Settings step; "Re-render" sends it through `generateMiniVideos`.
- Full wizard: shown in `WizardResultsSheet`'s header for the project and in
  the Wizard view next to Generate. Choosing an entry sets
  `lastWizardOptions` from `settings_json.options` (paths remapped by hash),
  shows the entry's plan clips, and "Generate again with these settings" runs
  `retryWizard`.
- A teammate's entry whose source video is not in the local library shows
  "Source video not in your library" and disables Open and Re-render.
- Tests: a pure `HighlightHistoryNavigation` helper (previous/next index,
  label formatting) with tests.

## Phase 3: team sync

- `Services/TeamSync/SyncTable.swift`: append after `footage`, in order:
  `projects` (name, created_at, last_opened_at, archived, is_home; natural
  key `[name, created_at]`), `project_videos` (project_id, video_id;
  references both; natural key both), `wizard_highlights` (project_id, flow,
  batch_id, parent_id, video_hashes_json, footage_json, settings_json,
  plan_json, provenance_json, note, author, created_at; references
  project_id→projects, parent_id→wizard_highlights; no natural key),
  `transcript_picks`, `fight_picks` (video_id, project_id, position,
  start_time, end_time, original_start, original_end, scene_id [, event_ids];
  references video_id, project_id, scene_id; no natural key), `qa_picks`
  (project_id, video_id, scene_id, position; references all three; natural
  key all three). Local-only columns (selection_id, take_id,
  generated_video_id, ui_state_json, thumbnail_video_id, profile_name) are
  not listed.
- `supabase/migrations/20261101120000_projects_highlights.sql`: the six
  tables in the phase2 style (sync_id, team_id, profile_id, columns,
  server_updated_at, updated_by, deleted_at, pull index, stamp trigger, RLS
  member policies, REVOKE/GRANT), ending with `schema_version = 8`.
- `SyncEngine.understoodSchemaVersion = 8`; update the pinned test.
- Not run by Claude: `supabase db push`. The user runs it (or asks Claude to)
  before shipping the client.
