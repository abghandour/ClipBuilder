# Projects — implementation plan

Source: `docs/ui-projects/README.md` (proposal and mockups) plus the
decisions recorded below, September 5, 2026. Same format as
`docs/PG-Implementation-Plan.md`: numbered build order, effort, dependencies,
and the decision each item rests on. Move items freely as long as a
dependency still comes first.

Effort: S = a day or two, M = about a week, L = two weeks or more.

## Decisions (settled)

- **D1.** Projects are per profile. A project never spans profiles.
- **D2.** Every profile has a **Home** project that contains every raw file,
  every scene, and every generated file in the profile. Home cannot be
  deleted, archived, or renamed. Adding a file to any project also shows it
  in Home; Home has no membership rows of its own and can never drift.
- **D3.** A file can belong to several projects. Its scenes, analysis
  batches, people tags, transcripts, and research are the same rows
  everywhere; membership is the only per-project fact.
- **D4.** Files that arrive in the Input folder appear in Home. Home offers
  "Add to project…". Dropping files into a project's Sources adds them to
  that project (and therefore to Home). The Inbox concept from the proposal
  is replaced by Home.
- **D5.** "Remove from project" is a per-project action that leaves the file
  and all its data in Home and in any other project that has it. It is never
  offered in Home.
- **D6.** Deleting a project deletes its timelines and nothing else. Outputs,
  files, scenes, and analysis stay and remain visible in Home. No record of
  the deleted project's name is kept. The confirmation shows how many
  timelines will go and offers "Move timelines to Home" as the alternative.
- **D7.** The Wizard is a sidebar item in every project and only ever plans
  from the current project's sources. In Home that is the whole library,
  which is today's Wizard.
- **D8.** The app reopens exactly where it was: last profile, last project,
  its section, open timeline, playhead, zoom, scroll, selection, and filters.
  Open sheets and dialogs are not restored.

## Where the working tree already is

An implementation is in progress (unstaged, ~30 files, `Project*` views,
`projects` / `project_videos` / `timelines` tables, `ProjectUIState`,
per-project Wizard scoping). It predates D2, D4, D5, D6, and D8 and differs
from them in four places, each called out under the item that fixes it:

- The migration creates one project named after the profile with no
  "home" role; any project can be deleted.
- Files not in a project sit in an Inbox (`fetchInboxVideos`).
- `deleteProject(_:removeOutputFiles:)` offers to delete generated files.
- UI state is saved per project, but nothing restores the last project on
  launch.

---

## Phase A — Data model aligned with the decisions

### 1. Home project  (S)
Add `is_home` to `projects`. The migration marks the profile's first
project as Home and names it "Home"; `ensureDefaultProject` creates Home
for a profile that has none. Home membership is implicit: every query that
filters by project treats Home as "no filter" instead of reading
`project_videos`. Delete, archive, rename, and duplicate-as-home are
refused for Home at the database layer, not only in the UI.
- Decisions: D2. Replaces: the profile-named default project.
- Depends on: nothing. Blocks: 2, 3, 4, 6.

### 2. Membership semantics  (S)
`fetchInboxVideos` and the Inbox view go away. A new file discovered by the
watcher needs no membership row (it is in Home by D2). "Add to project"
inserts a `project_videos` row; "Remove from project" deletes one and is
hidden in Home. `fetchVideosInOtherProjects` becomes "videos not yet in this
project", which now includes never-assigned files.
- Decisions: D3, D4, D5.
- Depends on: 1.

### 3. Delete semantics  (S)
`deleteProject` keeps its cascade on `timelines` only. Remove the
`removeOutputFiles` path and the "also delete files" choice from the
confirmation. Generated videos and Wizard runs whose `project_id` pointed at
the deleted project get `project_id = NULL`, which Home already shows. Add
`moveTimelines(from:to:)` so the confirmation can offer "Move timelines to
Home"; the dialog states the timeline count.
- Decisions: D6.
- Depends on: 1.

### 4. Wizard scope  (S)
Runs carry the project id (already done). Verify every planning input is
filtered by it: scenes, videos, fight research, outcomes, people tags,
saved framings, topic ranges, and cleanup proposals. In Home the filter is
off. Wizard outputs and pre-filled Builder timelines land in the run's
project.
- Decisions: D7.
- Depends on: 1.

---

## Phase B — Restore and navigation

### 5. Reopen where you left off  (S)
On launch: restore the last profile (exists), then the last opened
project of that profile (`last_opened_at`), then its `ProjectUIState`
(exists: section, open timeline, playhead, zoom, selections, scene
filters, outputs sort). Add scroll offsets for Sources, Scenes, Outputs,
and the timeline, and save state on every change with the existing
debounce plus on quit. Sheets are never restored.
- Decisions: D8.
- Depends on: nothing; uses 1 for the fallback to Home when the last
  project was deleted.

### 6. Home in the switcher and on the home screen  (S)
Home is pinned first in the project switcher and on the All Projects grid,
with no delete or archive actions and a distinct icon. The card shows the
profile's totals. New-project creation offers "start from selected Home
files" as today.
- Decisions: D2, D4.
- Depends on: 1, 2.

### 7. Wizard in the sidebar  (S)
"Wizard" is a PROJECT section for every project (the proposal demoted it to
a button; that is reversed). Timelines keeps "New from Wizard…" as a
shortcut to the same screen. In Home the screen is the current Wizard,
unchanged.
- Decisions: D7.
- Depends on: 4.

---

## Phase C — Verification

### 8. Tests  (M)
Database: Home creation and refusal of delete/rename; implicit membership
(a file in project A is listed in Home without a join row); remove-from-
project leaves data intact elsewhere; delete cascades timelines only and
nulls output ownership; move-timelines-to-Home. App store: launch restores
the last project and its UI state, and falls back to Home when that
project is gone. Wizard: a run in project A never sees project B's scenes;
a run in Home sees everything. UI smoke: switch projects with a render in
flight and confirm both the Activity summary and the output landing in the
right project.
- Depends on: 1–7.

### 9. Migration check on a real profile  (S)
Open the Peace Grappler database with the new build: one Home project,
all existing videos and outputs visible in it, the previous Builder
autosave present as its first timeline, no Inbox.
- Depends on: 1, 2, 5.

---

## Out of scope for now

Favorites replacing curated scenes, per-project People filtering, and any
change to the Studio screens. These will get their own items when picked
up.
