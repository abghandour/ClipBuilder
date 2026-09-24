# Async AI Actions Plan

Date: September 23, 2026. Status: approved for implementation (Codex), reviewed by Claude.

## Problem

Long AI and media jobs are started from modal sheets that stay open until the job
ends. While the sheet is up the window is blocked, so the user cannot browse
scenes, edit the Builder, or start anything else. Example: **AI Favorites** →
Judge Scenes keeps `AIFavoritesSheet` open with a spinner for one 240 s AI call per
chunk of scenes. The same shape appears in sixteen more places (inventory below).
Closing one of these sheets does not cancel the job either: the `Task {}` lives in
the view, so the AI call still runs and costs money, and the result lands in the
discarded view's `@State` and is lost.

The app already has the right pattern for Analyze, the Wizard, and Podcast
highlights: a store-owned task, a row in the status bar with Stop, and a result
sheet presented from the root `ContentView` when the job finishes. This plan
generalises that pattern into one job registry and moves every blocking action
onto it.

## Rules (apply everywhere)

1. **Start → dismiss.** Pressing the sheet's action button dismisses the sheet
   immediately and starts a store-owned job. Nothing that can take more than
   about two seconds runs while a modal is up.
2. **Visible and stoppable.** Every job is a row in the status bar activities
   list (`StatusBarSummary.activities`) with a Stop button, a status line fed
   by the job's log sink, and progress where the job knows it.
3. **Results survive the view.** Results are stored on the job, not in view
   state. Closing a sheet never cancels a job. Cancelling is only ever the Stop
   button or an explicit Cancel action.
4. **Review when ready.** When a job that needs review finishes, its review
   sheet is presented from the root `ContentView` (same as `wizardResults`),
   queued behind whatever store-presented sheet is already up. Closing the
   review without applying keeps a **Review** button in the status bar until the
   user presses **Dismiss**, so nothing is lost by closing at the wrong moment.
   Jobs that don't need review (apply-on-finish) post a `presentNotice` line
   instead. Failures go through `presentError(context:)`.
5. **Project-aware.** A job records the project it was started in. Its review
   sheet opens only when that project is active; otherwise the status bar button
   reads "Review in <project>" and switches to that project first
   (`selectProject`, await its task, then present). The existing
   `profileGeneration` guard applies the same way as in `renderPodcastHighlights`.
6. **No new menus at bar level.** Status bar affordances are plain buttons
   ("Review AI Favorites", "Dismiss"), following the existing toolbar rule.
7. **No main-thread work over ~50 ms.** CPU-bound helpers called from a
   main-actor `Task` run on the main thread; move them behind `nonisolated`
   async functions or `Task.detached`. `MainThreadWatchdog` logs stalls over
   0.5 s and is the acceptance check.

## Phase 1: job registry

New file `ClipBuilder/App/AppJobs.swift` (main-actor, `@Observable`), owned by
`AppStore` as `let jobs = AppJobs()` and modelled on `GoogleDriveTransfers`:

```swift
struct AppJob: Identifiable, Equatable {
    enum Status: Equatable { case running, done, failed(String), cancelled }
    let id: UUID
    let kind: AppJobKind            // enum, one case per job type; gives title + channel
    let title: String               // "AI Favorites — 30 scenes"
    let channel: String             // AppLogChannels channel for the log drawer
    let projectID: Int64?
    let projectName: String
    let profileGeneration: Int
    let startedAt: Date
    var status: Status
    var statusLine: String          // last AIProgressLine / log line
    var progress: Double?
    var result: AppJobResult?       // set on success when the job needs review
    var reviewed = false            // result was applied or explicitly dismissed
}

enum AppJobResult: Equatable {      // typed payloads, one per review sheet
    case favorites(candidates: [SceneRecord], proposals: [SceneCurator.Proposal], provenance: AIProvenance?)
    case soundbites(...)
    case duplicateReport(...)
    case fileNames(...)
    case gapReport(...)
    case profileStarter(...)
    case coverFrames(video: VideoRecord, ...)
    case sceneSearch(ids: [Int64], provenance: AIProvenance?, filterContext: ...)
    case imageSearch(...)
    case fightResearch(...)
    case instagramPublished(permalink: URL, ...)
    case resourceExport(url: URL) / resourceImport(summary: ...)
    case socialExport(urls: [URL])
}
```

API on `AppJobs`:

- `@discardableResult func start(_ kind: AppJobKind, title: String, project: ProjectRecord?, profileGeneration: Int, progress: ((Double) -> Void)? , body: @escaping (_ log: @Sendable (String) -> Void) async throws -> AppJobResult?) -> AppJob.ID`
  Runs `body` in a stored `Task`, updates `statusLine` through `AIProgressLine.from` (falls back to the raw line), sets `.done` + `result`, or `.failed(message)`, or `.cancelled` on `CancellationError`. On failure calls `store.presentError(context: title, error)`. On success with a result, appends the job id to `reviewQueue`.
- `func cancel(_ id: UUID)`, `func dismiss(_ id: UUID)` (removes finished job), `func markReviewed(_ id: UUID)`.
- `var running: [AppJob]`, `var awaitingReview: [AppJob]` (done, has result, not reviewed).
- `var presentedReview: AppJob?` — the head of `reviewQueue` **only while no other root sheet is up**; `ContentView` presents it via `.sheet(item:)` and a `switch job.result` that builds the right review view. Presenting it for another project follows rule 5.
- `busyProjectIDs` (`AppStore:135`) must include projects with running jobs so they cannot be deleted mid-job.
- Jobs are in-memory only (no persistence across launches).

Status bar (`AppStatusBar.swift`):

- `activities(store:)` adds one row per running job: `add("job-\(id)", job.channel, job.statusLine.isEmpty ? job.title : "\(job.title) — \(job.statusLine)", true, progress:, project:)`.
- `stopButton` default case: a running job id → `store.jobs.cancel`.
- `recoveryActions`: for each job in `awaitingReview`, a `Button("Review \(job.kind.shortTitle)")` (or "Review in <project>") and a `Button("Dismiss")`. For failed jobs: "Dismiss". At most the three newest are shown inline; the drawer lists them all.
- `AppLogChannels.known` gains the new channels (see kinds table).

Tests: `ClipBuilderTests/App/AppJobsTests.swift` covering start→done with result queued, failure→`.failed` and no result, cancel→`.cancelled`, `markReviewed` removes from `awaitingReview`, `presentedReview` is nil while another item is queued ahead, project mismatch keeps it in `awaitingReview`. Use a fake body closure; no AI calls.

## Phase 2: the eleven same-pattern AI sheets

Each currently has `@State isRunning`, a `Task {}` awaiting a store method, an
inline spinner, and a review/result view in the same sheet. Change every one to:
setup view → action button calls `store.jobs.start(...)` with the store method
as the body, then `dismiss()`. Split the review part into its own view, given
the `AppJobResult` payload plus the job id, and present it from `ContentView`.
The review's apply button applies and calls `markReviewed`; Cancel leaves the
job in `awaitingReview`.

| Sheet | Store method | Kind / channel | Review view | On apply |
|---|---|---|---|---|
| `AIFavoritesSheet` | `proposeFavorites` | `.aiFavorites` / `curate` | `AIFavoritesReviewSheet` (existing `review(_:)`) | `applyFavorites` |
| `SoundbiteSheet` | `findSoundbites` | `.soundbites` / `analysis` | results list + Save | existing save path |
| `DuplicateReportSheet` | `findDuplicateVideos` | `.duplicates` / `analysis` | report (read-only) | none; Dismiss |
| `FileNameWizardSheet` | `suggestFileNames` | `.fileNames` / `analysis` | rename editor | existing apply |
| `GapReportSheet` | `generateGapReport` | `.gapReport` / `wizard` | report + Copy + jump to Wizard | none |
| `ProfileStarterSheet` (Settings) | `generateProfileStarter` | `.profileStarter` / `app` | editable review | `applyProfileStarter` |
| `CoverFrameSheet` | `proposeCoverFrames` | `.coverFrames` / `analysis` | pick one | `setCoverFrame` |
| `OverlayWizardSheet` | `extractOverlayTemplate` | `.overlayTemplate` / `app` | none (apply-on-finish) | `presentNotice("Overlay created", name)` and the `onCreated` callback becomes a store-side refresh |
| `SceneSearchSheet` (Scenes "Ask") | `findScenes` | `.sceneSearch` / `analysis` | none | the Scenes view observes the finished job for the active project and applies the filter (`onResults` today); keep the query text in the result so the filter chip can show it |
| `ImageLibrarySearchSheet` | move the `store.ai.call` into a new `AppStore.searchImages(query:candidates:...)`; the local keyword path runs first inside the job, off-main | `.imageSearch` / `app` | none | same as scene search: the Asset browser applies the results |
| `FightResearchSheet` | `runFightResearch` (store already saves `fightResearch[id]`) | `.fightResearch` / `analysis` | the existing editable story view, opened on the saved research | Save as today |

`AIInfoSheet` opens `SoundbiteSheet` and `FileNameWizardSheet` on top of itself;
after this phase both dismiss on start, so `AIInfoSheet` stays usable.

## Phase 3: the other blocking flows

- **Generate Video Request dialog** (`WizardView.swift` `generateRequestModal`,
  `AppStore.generateSampleVideo`). Replace the modal with a non-modal banner at
  the top of the Wizard form ("Analyzing 3 videos, then interpreting your
  request…" with a spinner and a Stop button). The interpretation runs as a
  `.generateRequest` job, the form stays editable, and the banner fills the
  parsed settings in when done (a failed parse keeps the raw description as
  instructions, as now). Closing the banner cancels the interpretation but
  never the analysis. Remove the `description == trimmed` drop.
- **Instagram publish** (`InstagramPublishSheet`, `publishReelToInstagram`).
  Start → dismiss; job `.instagramPublish` / `instagram` with the existing
  `isPublishingToInstagram` folded into the job; on finish, result
  `.instagramPublished(permalink:)` shows a small review sheet with the
  permalink and Copy. Stop cancels the upload as `onDisappear` does today; the
  confirmation before stopping moves to the status bar Stop for this kind only.
- **Social format export** (`SocialFormatExportSheet`). Start → dismiss; job
  `.socialExport` / `builder`; result lists the exported files with Show in
  Finder. Remove the whole-sheet `.disabled(isExporting)`.
- **Resource export / import** (`ResourceBundleSheets`). Start → dismiss; jobs
  `.resourceExport` / `.resourceImport`, channel `app`; export result shows
  Show in Finder; import result shows the summary and calls
  `resourcesDidChange`.
- **Map Speakers Again** (`TranscriptSheet`, `mapSpeakersAgain`). Job
  `.mapSpeakers` / `analysis` keyed by video id, with the sheet's header
  showing the job's status line when one is running for its video. The
  transcript sheet may be closed; on finish the store reloads the transcript
  and, if the sheet is open for that video, it refreshes and shows
  `recutNote`. No review sheet.
- **Suggest Trim** (`DispatchPlanSheet`), **Center Stage path**
  (`SceneEditSheet.computeCameraPath`, `ManualBuildSheet.ensureCameraPath`),
  **Evaluate reel model** (`ReelModelsLearnedSection`), **AI Lessons publish**
  (`LearnedPreferencesView`). These fill controls inside the sheet they run
  from, so the sheet stays open, but each becomes a job so it appears in the
  status bar with Stop, and the sheet reads its status from the job instead of
  a local flag. Closing the sheet no longer cancels the job; the result is
  applied through the store (camera path saved on the scene, trim stored on
  the pending dispatch, model metrics stored) so reopening shows it.
- **Transcript Tools** (`TranscriptToolsSheet`). `analyzeTranscript` becomes a
  `.transcriptAnalysis` job whose CPU work runs off-main (see phase 4).
  Translation stays bound to `.translationTask` (Apple's API requires a view),
  but the sheet must not disable itself and must show that closing stops the
  translation.
- **Builder pre-fill** (`BuilderView` `.disabled(store.isPlanningIntoBuilder)`).
  Replace the whole-pane disable with a banner in the Builder plus the existing
  status bar row; only the Wizard button that started it is disabled.

## Phase 4: main-thread stalls

- `TranscriptToolsSheet.swift:172-179`: run `TranscriptFeatureAnalyzer.analyze`,
  `TopicSegmenter.segment`, and `CleanupCutPolicy.applied` inside the job
  body via `Task.detached` / `nonisolated` helpers; only the DB write and
  `load()` return to the main actor.
- `AppStore.extractOverlayTemplate` (`:2694-2759`): image read and PNG writes
  off-main.
- `AppStore` `:4078` and `:4166`: `WizardBrain.assemble` + write and the frame
  import writes off-main.
- `EditingPerformanceView.swift:141`: `ReportCSVExporter.export` off-main with
  a spinner on the button.
- `WizardSheetModel.swift:1099`: `ProcessRunner.locate` from the main actor can
  spawn a login shell and block on `waitUntilExit`; resolve it inside the job
  body or cache at launch.
- `BuilderBRollPickerSheet.swift:133`: compute `MediaSuggestionService.suggestions`
  in a `.task(id:)` off-main with a short debounce, not in the view body path.
- `ImageLibrarySearchSheet`: the per-image `resourceValues` scan moves into the
  job body.

## Out of scope

Player-bearing sheets awaiting `DrivePlayback.prepare` (the download is already
a Transfers job), `AvatarPickerSheet`, `ProjectVideoPickerSheet`, the debug
script preview, and the update/tools HUD.

## Verification (Claude, after Codex)

Codex's sandbox cannot run `xcodebuild`, so Claude builds and runs
`scripts/test.sh` after each phase lands, then drives the app: start AI
Favorites, close nothing, confirm the sheet is gone, the status bar row shows
the chunk progress with Stop, scrolling and favoriting in the grid work
meanwhile, and the review sheet appears when the run finishes. Repeat with the
Generate Video Request path from Analyze with an un-analyzed video. Watch the
log for `MainThreadWatchdog` stalls while running Transcript Tools on a
podcast transcript.
