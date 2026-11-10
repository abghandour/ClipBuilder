# Selection Sync and Revert Plan

2026-11-10 · Status: shelved by the user on 2026-11-10, not implemented. Kept for later; the decisions at the end are still open.

## Goal

In the AI Wizard (Express and Full), a "Revert to last sync" control puts the
footage selection of the recording on screen, in the current project, back to
how it was when Team Sync last ran. The user syncs, plays with picks, keeps and
trims, and can throw all of it away.

User decisions (2026-11-10): everything the footage selection writes joins
Team Sync first, then revert restores all of it; one revert covers this
video in this project.

## What the footage selection writes today

| State | Where | Synced |
| --- | --- | --- |
| Transcript picks (range, kept, order) | `transcript_picks` | yes |
| Q&A keeps and order | `qa_picks` | yes |
| Q&A trims | `scenes.edit_start/edit_end` (library-wide) | yes |
| Fight picks | `fight_picks` | yes |
| Scenes and tags made when picks become selections | `scenes`, `scene_tags` | yes |
| Highlight history snapshots | `wizard_highlights` | yes |
| Selections and takes (Express highlights, all of Full: Accept, Best take, trims, Delete) | `wizard_selections`, `wizard_selection_takes` | no |
| Express reel list | `express_reel_items` | no |
| Highlights keep / order per batch | UserDefaults `mini.kept.<batch>`, `mini.order.<batch>` | no |
| Current batch per project, video and length | UserDefaults `mini.<profile>.batch.*` | no |
| Full wizard source choice | UserDefaults `wizard.limitToSelection`, `wizard.selectedRunIDs`, `wizard.sourcePeople`, `wizard.favoritesOnly` (global, local run ids) | no |
| Which recording Express shows, card height, tab, length | UserDefaults `mini.<profile>.*` | no (stays local) |

A sync only runs on Sync Now, on attaching a team, and when an Analyze batch
finishes. There is no timer, so "the last sync" does not move while the user
experiments.

## How revert works

The database already keeps, per synced row, the row as the server last had it
(`sync_wire_rows`) and the list of rows changed since (`sync_outbox`). Revert
needs no network:

1. Collect the outbox entries of the tables in scope whose row belongs to
   this video and project. A deleted row is matched through its cached copy.
2. A row with a cached copy is put back from it through `applySyncRows`
   (server wins, cursor untouched), which also re-creates a deleted row.
3. A row with no cached copy was made since the sync: it is deleted, with the
   triggers suspended. Exception: `scenes` rows are never deleted by a revert.
   A reel or timeline made since the sync may point at them, and an unused
   scene is inert.
4. Their outbox entries are removed, so nothing reverted is pushed.
5. The wizard reloads; the Express reel list is rebuilt by the existing
   reconcile.

It is one transaction, a pure database function with tests beside the sync
engine tests (two-store harness: change, revert, sync, compare).

The control: a "Revert to Last Sync…" button on the Express Footage card and
in the Full wizard's footage toolbar, with a confirmation that counts what
will be discarded. Disabled with a reason when the profile is not in a team,
when nothing changed since the sync, and while a sync runs.

## Phases

1. **Revert for what already syncs.** `Database.revertSelection(videoID:projectID:)`
   over `transcript_picks`, `qa_picks`, `fight_picks`, `scenes` (edit range
   only) and `scene_tags`; store action; the Express button. No schema change.
2. **Selections and takes sync.** `wizard_selections`, `wizard_selection_takes`
   and `express_reel_items` gain `sync_id` and join `SyncTable.history`.
   Takes carry scene references as local ids inside `plan_json` and
   `scene_ids_json`; they travel as scene sync ids, translated like
   `fight_picks.event_ids`. `proxy_path` stays local. `best_take_id` and the
   take's `selection_id` form a cycle: the take is pulled first with a parked
   parent, as scenes already do.
3. **UserDefaults state moves into the database.** New table
   `wizard_selection_state(project_id, video_id, key, value_json)` holds the
   highlights keep and order per batch, the current batch, and the Full
   wizard's source choice (run ids as run keys). One-time import of the
   existing keys, as `qa_picks` did. Joins sync.
4. **Revert covers the new tables, and the Full wizard gets the button.**
5. **Server.** One Supabase migration for the four new tables. Sync schema
   stays 13 if this ships with voice profiles, otherwise 14; the gate is
   exact, so the migration is applied only with the release.

Phase 1 is useful alone. Phases 2 to 4 are one release.

## Risks

- Selections become shared: a teammate's Accept, Best take or highlight keep
  replaces mine on the next sync (last write wins per row). Today each Mac has
  its own.
- Q&A trims are library-wide. Reverting them for this video also changes the
  Transcript sheet and other projects using the same Q&A.
- `plan_json` embeds local ids. A missed reference syncs a plan that points
  at the wrong scene on another Mac. Needs a round-trip test per plan shape.
- A debug build stamps the local schema; installed releases then refuse the
  database. Develop on scratch data.

## Decisions needed

1. Sharing selections with the team changes behaviour for teammates (first
   risk). Confirm that is wanted, or keep selections per Mac and restore them
   from a local snapshot taken at each sync instead.
2. Ship with the voice profile release (schema 13) or as its own (schema 14).
3. Start with Phase 1 now (Express, synced parts) while the rest is built.
