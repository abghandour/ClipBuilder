# Add from Home: finding the profile's videos from any project

Date: November 2, 2026. Status: planned, Codex implements Phases 1–3, Claude
verifies. Requested by the user on November 2, 2026 after opening an empty
project's Sources page and finding no way to reach the videos already in the
profile.

## What the user asked for

Every file added to the app is always visible from the Home project (the
default). Any other project needs a visible way to add files that are part of
Home.

## What exists today

- The model already does the first half (docs/ui-projects/IMPLEMENTATION-PLAN.md
  D2–D4): `projects.is_home`, Home has no `project_videos` rows and every
  project-scoped query treats Home as "no filter"
  (`Database+Videos.fetchVideos(projectID:)` via `scopedProjectID`).
  `importVideos(_:toProjectID:)` (`App/AppStore.swift` ~1631) copies the files
  into the profile's Input folder and inserts membership rows, so a file added
  in any project is also in Home.
- `Database+Projects.swift`: `assignVideos`, `removeVideos`,
  `fetchVideosNotInProject(_:)` (every non-hidden video without a membership
  row for this project), `projectIDs(forVideo:)` (one query per video).
- `Views/ProjectVideoPickerSheet.swift`: a plain list titled "Add Existing
  Videos" with thumbnail, name and duration; footer "Add N to Project". Loaded
  through `AppStore.availableVideosForProjectPicker()`.
- The sheet's only entry point is the footer icon button "Add existing
  videos" (`Views/AnalyzeView.swift` ~645, `folder.badge.plus`) with the
  misleading help "Add videos that are already in another project". The
  toolbar (~292) offers only "Add Videos" (Finder importer) and "Add from
  Google Drive…". The empty state (~1081) says "Drop video files here, or add
  them from Finder" and offers one button, "Add Videos…". None of these
  mention Home.
- In Home the footer shows an "Add to project" menu for the selection and the
  row context menu has "Add to Project…" (~1053).
- `Services/Assistants/SourcesAssistant.swift`: when `sources == 0` the only
  suggestion is "Add source videos" → `sources.add` (Finder importer).
  Actions are `AssistantAction(id:title:systemImage:isAvailable:run:)`; page
  view commands are handled in `AnalyzeView.runAssistantCommand` (~145).

## Design

### Toolbar (non-Home projects)

Replace the "Add Videos" button with a Menu labelled the same way
(`ToolbarBubbleLabel(text: "Add Videos", systemImage: "plus")`, menu
indicator hidden like the Builder's More Actions menu). Items:

- "From Finder…" → `showingImporter = true`
- "From Home… (N available)" → `showingProjectVideoPicker = true`, where N is
  `store.homeVideosNotInProjectCount`; disabled with "(none available)" when 0.
- "From Google Drive…" → `showingDriveBrowser = true`

In Home the toolbar keeps the plain "Add Videos" button; the "Add from Google
Drive…" button stays in both cases (it is also in the menu outside Home so the
menu is complete). Menu rows are `lineLimit(1)` text; the label never wraps.

The primary action of the menu (click on the label) is "From Finder…" so the
existing one-click path is unchanged: use `Menu(..., primaryAction:)`.

### Empty state (non-Home projects)

When `store.videos.isEmpty && !store.isHomeProject`:

```
Label("No sources in <project name> yet", systemImage: "film")
Text("Add new files, or pick from the N videos already in this profile's Home project.")
   // N == 0: "Add new files; Home has no videos yet either."
actions:
   Button("Add from Home…")  .borderedProminent when N > 0
   Button("Add Videos…")     .borderedProminent when N == 0, else .bordered
```

Home keeps the current empty state text.

### Sheet: "Add from Home"

`ProjectVideoPickerSheet` keeps its name and API, gains:

- `.navigationTitle("Add from Home")`, a subtitle line "Videos in this profile
  not yet in <project name>" above the list.
- A search field (`.searchable` is not used inside sheets in this app; use a
  `TextField` with `magnifyingglass` like `ClipBrowserPane.fileSearch`).
- A segmented filter: All, Analyzed, Transcribed, Unassigned.
  - Analyzed: `store.analysisRuns`/scenes are project-scoped, so the sheet
    needs profile-wide facts. Add `Database.fetchVideoFacts(ids:)` returning
    per-video `hasScenes` (any row in `scenes` for the video), `hasTranscript`
    (any row in `transcripts`), and `projectIDs` (from `project_videos`), in
    one query each, not per video. Pure filter logic goes in a
    `nonisolated enum HomeVideoFilter` under `Services/` with a test.
  - Unassigned: `projectIDs.isEmpty`.
- Rows: thumbnail, filename, created date (`createdDate` as the table shows
  it), duration, and project chips (names of ordinary projects the video is
  in, `Text` in a capsule, `lineLimit(1)`; at most three then "+N").
- "Select All" / "Deselect All" button in the footer, footer primary button
  "Add N to <project name>".
- Empty filter result: `ContentUnavailableView("No matching videos")`; empty
  source: keep "No Videos to Add" with text "Every Home video is already in
  this project."

`AppStore.availableVideosForProjectPicker()` returns the videos and the facts
together (`[HomeVideoCandidate]` = record + facts) so the sheet does one load.

### Count for the menu and empty state

`AppStore.homeVideosNotInProjectCount: Int` refreshed with the project
catalog (`refreshProjectCatalog`) and after `importVideos`, `addVideos`,
`removeVideos`, `removeSources`. Backed by
`Database.countVideosNotInProject(_:)` (COUNT of the existing
`fetchVideosNotInProject` query). Zero in Home.

### Drop and log

`importVideos(_:toProjectID:)` already logs added files; append "to <project>
and Home" to that line outside Home so the drop confirms where the file went.

### Footer and context menu

- The footer icon button keeps `folder.badge.plus` but reads "Add from Home"
  with help "Add videos already in this profile's Home project".
- The Home row context menu "Add to Project…" and the footer menu are
  unchanged.

### Home: Projects column

In Home only, the Sources table gets a "Projects" column after Type: the
names of ordinary projects the video belongs to, joined with ", ",
`lineLimit(1)`, "—" when none. Sortable by the joined string. Data comes from
one batched query `Database.projectNames(forVideos:)` (video id → [name]),
loaded with the table summary and cached in the view until the catalog or
videos change. Outside Home the column is omitted.

### Ask AI

`SourcesAssistant`: when `sources == 0` and `context.int("home.available") > 0`
(new snapshot value, 0 in Home), add an insight before the "Add source
videos" row: id `sources.addFromHome`, kind `.insight`, title
"Home has N videos not in this project", reason "Pick the ones this project
needs", actionID `sources.addFromHome`. The action selects the Sources
section and sets a store flag the page consumes
(`AnalyzeView.runAssistantCommand` case `"sources.addFromHome"` →
`showingProjectVideoPicker = true`), the same pattern as `sources.add`.

## Phases

### Phase 1: data (Codex)

- `Data/Database+Projects.swift`: `countVideosNotInProject(_:)`,
  `projectNames(forVideos:)`, `fetchVideoFacts(ids:)`.
- `Data/HomeVideoCandidate.swift`: `nonisolated struct HomeVideoCandidate:
  Identifiable, Sendable` (video, hasScenes, hasTranscript, projectIDs,
  projectNames) and `nonisolated enum HomeVideoFilter { case all, analyzed,
  transcribed, unassigned; static func apply(_:search:to:) }`.
- `App/AppStore+Projects.swift`: `homeVideosNotInProjectCount`,
  `refreshHomeAvailability()`, `availableVideosForProjectPicker()` returns
  `[HomeVideoCandidate]`.
- Tests: `ClipBuilderTests/Data/HomeVideoFilterTests.swift` (filter and
  search), a `TempDatabase` test for the three queries including a video in
  two projects and one in none.

### Phase 2: Sources page (Codex)

- `Views/AnalyzeView.swift`: toolbar menu, empty state branch, footer button
  rename, Projects column in Home, `sources.addFromHome` command, drop log.
- `Views/ProjectVideoPickerSheet.swift`: title, subtitle, search, filter,
  chips, Select All, footer label.

### Phase 3: Ask AI (Codex)

- `Services/Assistants/SourcesAssistant.swift`: snapshot value
  `home.available`, the insight, the action.
- `ClipBuilderTests/Services/Assistants/SourcesAssistantTests.swift`: the
  insight appears for an empty project with Home videos and not in Home.

### Phase 4: verification (Claude)

- Debug build, run the Assistants and Data suites.
- Drive live on scratch data: open a non-Home project with no sources,
  confirm the empty state and menu count, add two videos from Home with the
  Transcribed filter, confirm `project_videos` rows and the Projects column
  in Home.

## Out of scope

- Moving files between projects (membership is add/remove only).
- Syncing anything new: `project_videos` already syncs.
- Dragging rows out of the sheet.
