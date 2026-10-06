# Team Sync Plan

Date: October 2, 2026. Status: Phase 0 implemented on October 6, 2026; verification pending.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).

## Problem

Clip Builder is single-user. Everything a profile knows lives in one SQLite
file on one Mac (`data/profiles_db/<Profile>.db`, 57 tables) plus the profile
JSON. A second person working on the same brand starts from nothing: they
re-run the AI analysis on the same footage, cannot see the Instagram reports
unless they hold their own token, do not get the learned lessons, and cannot
open a teammate's timeline.

The user's requirements (October 2, 2026):

- a small team, 2–3 people, sharing largely the same footage;
- two people can sometimes work on the same timeline, matched to footage by
  video fingerprint;
- the app keeps working offline.

## Goal

A profile can be attached to a team. Attached, the profile's shared data
follows every member: analysis done once is available to all, reports and
lessons are common, timelines open on any member's Mac that has the footage.
Detached, or with no network, the app behaves exactly as today.

## Decisions

- **S1. SQLite stays the working store.** Every screen keeps reading the
  local database. Supabase is a sync target, never a query path. This is what
  makes offline work and keeps the 57 tables' query code untouched.
- **S2. Optional, per profile.** No team means no sync code runs and no
  network traffic, as with the Drive home in the Asset Sync plan.
- **S3. Local integer ids stay; a sync id is added.** Synced tables gain
  `sync_id TEXT` (UUID, unique). Local foreign keys keep using integers. On
  the wire, a row is identified by `sync_id` and refers to other rows by
  their `sync_id` or natural key (`videos.hash`, `people.key`, Instagram
  username and media id). The sync engine maps both ways when applying.
  Replacing integer keys across the schema is not needed.
- **S4. Footage is identified by fingerprint.** `videos.hash`
  (`ContentHash.fingerprint`: first MB + last MB + size) is already unique
  per file. Anything derived from footage is keyed to it. `videos.path` and
  every other local path column never leave the Mac.
- **S5. Files stay on Google Drive.** Source footage, renders and library
  assets keep the existing Drive features. Supabase holds rows, not media.
- **S6. Secrets stay local.** Instagram tokens, Drive tokens and AI keys
  remain in the Keychain and local settings. One member's Instagram
  connection feeds reports to the whole team because the fetched rows sync.
- **S7. Changes are captured by triggers.** SQLite triggers on each synced
  table write `(table, sync_id, op, changed_at)` to a local `sync_outbox`.
  No existing write call changes. The engine suspends the triggers while it
  applies pulled rows.
- **S8. The server orders changes.** Every server row carries
  `server_updated_at` set by a Postgres trigger, `updated_by`, and
  `deleted_at`. Pull is "rows newer than my cursor, per table". Client clocks
  are never compared.
- **S9. Deletes are tombstones.** A delete syncs as `deleted_at`. Tombstones
  are kept 90 days so a Mac that was offline still learns of the delete.

## Conflict rules

- **Records** (lessons, people, grades, scene flags, reports): last write
  wins per row, by server time. With 2–3 people this is rare and low stakes.
- **Timelines**: never merged, never silently overwritten. Each timeline has
  a `revision`. A push sends the revision it was based on. If the server has
  moved on, the server copy becomes current locally and the local edits are
  kept as a second timeline named "<name> (<member>'s copy)". The member
  sees a notice and reconciles by hand.
- **Editing presence** (advisory): opening a shared timeline writes a
  heartbeat row that expires after two minutes. Others see "<member> is
  editing" on the timeline card and in the Builder. It warns; it does not
  lock, so a crashed Mac never blocks anyone.
- **Analysis**: two members analyzing the same file produce two
  `analysis_runs`. Both are kept; scenes are already unique per run.

## Portable timelines

`TimelineClip` refers to footage by `sceneID` (a local integer) and
`videoFile`. The synced form adds `videoHash` to each clip beside the existing
`sourceStart` and `sourceEnd`. On load:

1. find the local video with that hash;
2. resolve `sceneID` through the scene's `sync_id`, else by time range;
3. if the footage is not on this Mac, the clip shows as missing with the
   file name and, when the video has a Drive file id, a download action.

A timeline with missing footage opens and can be read; it cannot render
until the footage is present. This rule is a pure function with tests.

## What syncs

| Phase | Tables | Notes |
| --- | --- | --- |
| 1. Brand knowledge | profile JSON (brand, rubrics, house style, critic brief use), `wizard_lessons`, `taste_studies`, `people`, `text_overlay_presets`, `library_asset_metadata`, all `ig_*` report tables, `reel_traits`, `reel_outcomes` | Small, low conflict. Members without a token see full reports. |
| 2. Footage analysis | `videos` (hash, name, duration, size, layout; not path), `analysis_runs`, `scenes`, `scene_tags`, `moments`, `transcripts`, `speaker_turns`, `transcript_features`, `topic_ranges`, `video_people`, `person_markers`, `video_subjects`, `video_notes`, `grades`, `fight_*`, `wizard_research` | Analysis is paid for once. Rows for footage a Mac lacks still arrive, shown as "not on this Mac". |
| 3. Work | `projects`, `project_videos`, `timelines`, `generated_videos` (record, caption, publish state; file via Drive), `generated_video_traits`, `generation_reviews`, `clip_reviews`, `wizard_feedback`, `wizard_preferences`, `edit_proposals` | Uses the timeline rules above. |

Never synced: `analysis_checkpoints`, `transcript_backups`, `voice_profiles`,
`center_stage_hints` (local frame paths), `builder_prerequisites`,
`imported_externals.local_path`, `ui_state_json` and `view_state_json`,
`drive_settings`, `app_settings.json`, caches, thumbnails, Keychain items.

## Supabase side

- A new Supabase project for Clip Builder, separate from VerticalCorn's.
  SQL migrations live in the repo under `supabase/migrations`.
- Tables mirror the synced tables with `team_id`, `profile_id`, `sync_id`
  (primary key), `server_updated_at`, `updated_by`, `deleted_at`.
- Row-level security: a row is visible and writable only to members of its
  team. `teams`, `team_members`, `team_invites` carry membership.
- Auth: email one-time code. No passwords stored or typed into the app.
- A `schema_version` row. The app stops syncing, and says so, when the server
  is newer than it understands; it keeps working locally. Server migrations
  are additive only.

## Client

- `Services/TeamSync/`: `SupabaseClient` (URLSession against the REST and
  auth endpoints, same injected-transport pattern as `GraphAPIProvider`, so
  tests stub the network), `SyncEngine` (actor: push outbox, pull by cursor,
  apply with id mapping), `SyncMapping` (pure, per-table wire format), and
  `TimelinePortability` (pure).
- Sync runs at launch, on network return, every 60 seconds while the app is
  frontmost, and from a Sync Now button. It runs off the main actor in
  batches and never blocks a screen.
- Visible state: a status-bar item (synced / syncing / offline with N
  changes waiting / needs update) and a Settings › Team tab (sign in, create
  or join a team with an invite code, attach this profile, pause sync,
  members list).
- First attach uploads the profile's existing rows after a confirmation that
  shows the row counts. Joining an existing team merges by natural key
  (same footage hash, same person key, same Instagram media id) so two
  members who both analyzed a file do not get duplicates of the video row.

## Phases

0. **Foundations (M).** Supabase project, schema and RLS for one table, auth,
   `sync_id` and outbox migration, engine round trip for `wizard_lessons`
   between two data folders on one Mac. Proves S3, S7, S8, S9.
1. **Brand knowledge (M).** Phase 1 tables, Settings › Team, status-bar item.
2. **Footage analysis (L).** Phase 2 tables, "not on this Mac" state in
   Sources and Scenes.
3. **Work (L).** Portable timelines, revision conflict copies, presence,
   generated-video records.

Each phase ships on its own and is useful without the next.

## Tests

- `SyncMappingTests`: every synced table round-trips local row → wire →
  local row with integer ids remapped; path columns are absent from the wire.
- `SyncEngineTests` against a stubbed transport: push then pull converges two
  databases; an offline period with edits on both sides converges; a
  tombstone removes the row on the other side; pulled rows do not re-enter
  the outbox; a newer server schema stops sync without touching local data.
- `TimelinePortabilityTests`: hash and time-range resolution, missing
  footage, a clip whose scene was re-analyzed.
- `TimelineConflictTests`: a stale revision produces the named copy and
  loses nothing.
- Migration test: a version-20 database gains `sync_id` on every synced
  table with unique values, and existing queries still pass.

## Risks

- **Id mapping errors** corrupt references silently. Mitigation: mapping is
  pure and tested per table; apply runs in one transaction per batch with
  `foreign_key_check` in Debug builds.
- **Assumptions of one own account or one writer.** The October 1 history
  import put one account's data into another. Every "the own account" or
  "the latest" lookup touched by a synced table is reviewed in its phase.
- **Privacy.** Transcripts, people names and Instagram audience data leave
  the Mac. The attach confirmation says so.
- **Mixed app versions.** An older app must not drop columns it does not
  know. Unknown wire fields are preserved, not discarded.
- **Cost.** The largest profile is 16 MB; the Supabase free tier covers a
  team of three.

## Relation to other plans

- `Asset-Sync-Implementation-Plan.md`: asset files keep syncing through the
  Drive home. Its learned-preferences document is superseded for team
  profiles by phase 1 and stays for profiles without a team.
- `Instagram-Multi-Account-Plan.md`: connections stay per Mac. Synced
  `ig_accounts` rows mean a member can view an account they have not
  connected; publishing still needs their own connection.

## Open questions

1. Should sync be automatic as described, or manual only like the Drive
   asset Refresh?
2. Can any member delete shared rows (a timeline, a lesson), or only the
   team owner?
3. Should footage rows for files a member does not have appear in Sources,
   or stay hidden until the file arrives?
4. Is email one-time code acceptable for sign-in, or should it be Sign in
   with Apple?
