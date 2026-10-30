# Page and tab switching performance

Date: October 29, 2026. Status: planned, not started. Implementer: Codex.
Reviewer: Claude (build, live driving, review).

## What the user asked for

"Review the UI for performance improvements on how the user can change between
pages and tabs." Pages are the sidebar sections rendered by
`ClipBuilder/Views/ProjectWorkspaceDetail.swift`; tabs are the Express footage
kinds (Footage / Q&A / Transcript / Highlights) in
`ClipBuilder/Views/MiniWizardView.swift` and the Text Looks tabs.

## Evidence

- `~/Documents/ClipBuilder/data/logs/app.log` holds 76 `[hang]` stalls over
  0.5 s from October 26 to 29, 2026, in bursts up to 4.7 s.
- Of the eight `diagnostics/hang-*.txt` samples, only two caught the main
  thread busy (October 28, 08:38:24 and 08:38:44). The first is SwiftUI
  building one `ForEach` whose elements carry about thirteen modifiers each
  (`ModifiedViewList.applyNodes` x14, `ModifiedElements.makeElements` x13).
  The second is text layout and font resolution for the same content. That
  shape matches exactly one view: the transcript word panel.
- The stalls on October 29 at 22:40, 23:10 and 23:11 happened while the
  Transcript tab was in use with Follow on.
- Profile "Peace Grappler": 16 videos, 807 scenes, 198 exports. The largest
  transcript has 11,332 words; one speaker turn is one line of hundreds of
  words. Export timeline JSON totals 1 MB (avg 5.4 KB, max 54 KB).
- `UITiming` logs only Sources selection latency (250 to 500 ms click to
  selection today), so page-switch latency is invisible in the log.

Caveat: these stalls came from the Xcode Debug build (`DerivedData/.../Debug`).
Release bodies are several times faster; the structural problems below remain.

## Rules

- Nothing CPU-bound over ~50 ms on a main-actor Task (CLAUDE.md). Pure
  logic goes in a `nonisolated` enum or struct under Services with a test.
- Do not change behaviour: selections, picks, drag gestures, Follow, anchors
  and word clicks must work as before. Each phase is a separate commit and
  can ship alone.
- Measure before and after with the timing added in Phase 0. Report numbers
  in `HANDOFF.md`.

## Phase 0: instrumentation

Files: `ClipBuilder/Services/Diagnostics/UITiming.swift`,
`ClipBuilder/Views/ProjectSidebarView.swift`,
`ClipBuilder/Views/ProjectWorkspaceDetail.swift`,
`ClipBuilder/Views/MiniWizardView.swift`,
`ClipBuilder/Services/Diagnostics/MainThreadWatchdog.swift`.

1. Add `UITiming.sectionChanged(to:)` and `UITiming.expressTabChanged(to:)`
   following `selectionChanged(screen:count:)`: log milliseconds since the
   last mouse-down, open a signpost. Close it with `responseReady` from the
   destination's first `onAppear` (section) or when the Express run for the
   new kind is non-nil (tab).
2. Six of eight watchdog samples landed after the stall ended. Lower
   `sampleThreshold` to 0.6 s (keep `logThreshold` 0.5 s) so a sample starts
   while the stall is still running. Keep the existing rate limit.
3. Test: add `ClipBuilderTests/Services/UITimingTests.swift` for the new
   log line formatting (there is no UITiming test today).

## Phase 1: transcript word panel

File: `ClipBuilder/Views/TranscriptQAWordPanel.swift` (helpers in
`ClipBuilder/Services/TranscriptQATrim.swift`; `FlowLayout` lives in
`ClipBuilder/Views/Instagram/ReportComponents.swift`).

Problem: `wordToken(_:)` builds a Button with about thirteen modifiers and a
`GeometryReader` preference per word. Every token reads `playback.time`, so
each 0.1 s tick while playing re-evaluates every visible word. Every frame
preference change recomputes `lineStartWordIDs`, which every token reads,
so all visible words re-evaluate again.

1. Compute the spoken word once per body: `spokenWordID: Int?` from
   `transcript` and `playback.time` (only while `playback.isPlaying`). Pass
   each line `spokenWordID` only when it belongs to that line, otherwise nil.
2. Extract the line into its own `struct TranscriptQALineView: View` with
   value inputs (line, column width, the selection range clipped to the
   line, the saved ranges that touch the line, `spokenWordID`, the line's
   start-word IDs, flags) and the callbacks. Mark the value inputs
   `Equatable` and apply `.equatable()` so SwiftUI skips lines whose inputs
   did not change. Callbacks must not be part of the equality.
3. Replace the per-word `GeometryReader` with one preference per line that
   reports every word frame of that line from the `FlowLayout` placement
   (add an optional `onPlace: ([Int: CGRect]) -> Void`-style hook or a
   `Layout` cache that exposes placed frames via an anchor preference).
   The merged `frames` dictionary keeps its current shape so the anchors,
   drag preview and `lineStartWords` keep working.
4. `refreshLineStarts()` runs on frames change: debounce it to the next run
   loop turn and compute only for the lines whose frames changed.
5. Verify: play a long transcript with Follow on for 60 s; the hang log must
   stay empty and Instruments must show one line re-evaluating per tick.
   Tests: `TranscriptQATrimTests` for any new pure helper; drive the
   Express Transcript tab live (mark a span by drag, anchors, word click,
   Add, Clear, Follow).

## Phase 2: Sources comparison refresh

Files: `ClipBuilder/Views/AnalyzeView.swift`,
`ClipBuilder/App/AppStore+AnalysisRequests.swift`.

Problem: `comparisonRevision` increments on appear, on every
`UserDefaults.didChangeNotification` (pane widths, Text Looks tab memory,
Express answers), on app activation, and on videos / runs / people changes.
Each refresh calls `captureAnalysisRequest` for every present video: four
database fetches including the full transcript, plus a fingerprint task.

1. Replace the `UserDefaults` observer with the specific keys the plan reads:
   derive a `planKey` string from `AnalysisRequest.capturePlan(...)` and
   bump the revision only when it changes.
2. Memoize previews in the store by `(video.id, planKey, video.hash,
   transcriptCountsVersion, videoPeopleVersion)`; skip videos whose key is
   unchanged. Drop the transcript fetch from the preview path when the plan
   does not use it (already gated by `usesTranscript`; keep).
3. Test: a unit test for the memo key in a `nonisolated` helper.

## Phase 3: Exports folder build

Files: `ClipBuilder/Views/LibraryView.swift`,
`ClipBuilder/Services/OutputFolders.swift`.

Problem: `rebuildFolders()` runs `OutputFolders.build` on the main actor on
appear and on every `generatedVideos`, `scenesVersion` or `timelines`
change; it decodes every export's timeline JSON (198 blobs, 1 MB).

1. Run the build in a `Task.detached(priority: .userInitiated)` and assign
   the result with a version guard (same pattern as `AssetBrowserView.refresh`).
   `OutputFolders` is already `nonisolated`; keep it pure.
2. Cache the decoded `sourceNames` per `(record.id, record.timelineJSON.hashValue)`
   inside `OutputFolders` so a scenes change does not re-decode unchanged
   exports.
3. Tests: `ClipBuilderTests/Services/OutputFolderTests.swift` exists; add
   one for the cache hit path.

## Phase 4: page switch re-entry work

Files: `ClipBuilder/Views/ProjectWorkspaceDetail.swift`,
`ClipBuilder/Views/ScenesView.swift`, `ClipBuilder/Views/TransitionsView.swift`,
`ClipBuilder/Views/LooksView.swift`, `ClipBuilder/Views/ScreenCropsView.swift`,
`ClipBuilder/App/AppStore+Projects.swift`.

Problem: the `switch` recreates the destination, so each visit reruns
appear-time work: three database tasks per visible Sources row, the Scenes
restore and search, `fileExists` per effect plus a preview render in
Transitions and Looks, `ScreenCropStore.list()` on the main thread.

1. Keep the three heaviest pages (Sources, Scenes, Exports) alive once
   visited: render them in a `ZStack` with `opacity` and `allowsHitTesting`
   driven by `selectedSection`, other sections stay in the `switch`.
   Confirm memory stays flat (Instruments Allocations) and keyboard focus
   moves with the visible page.
2. Transitions and Looks: move `loadCached()` (N `fileExists`) into the
   existing render task and only call `renderSelected()` when the selected
   effect has no cached preview.
3. Screen crops: call `ScreenCropStore.list()` through a `Task.detached`
   and assign on return; it already has a listing cache.
4. `selectSection(_:)` calls `persistActiveProjectState()` and the
   `selectedSection` didSet schedules a second save 400 ms later. Keep only
   the scheduled save.

## Phase 5: Express footage tabs

Files: `ClipBuilder/App/AppStore+MiniWizard.swift`,
`ClipBuilder/App/AppStore+MiniTranscript.swift`,
`ClipBuilder/App/AppStore+MiniFight.swift`, `ClipBuilder/App/AppStore.swift`,
`ClipBuilder/Views/MiniWizardView.swift`.

Problem: `miniRun` is a single slot. Changing Footage kind discards it,
refetches transcripts, picks, speakers and saved candidates, and
`beginWizardSelectionWork` sets `isWizardRunning` so the pickers grey out
while loading. Switching back reloads again.

1. Add `miniRuns: [MiniWizardFlow.FootageKind: MiniWizardRun]` keyed per
   video; `miniRun` becomes the entry for the current kind. Keep the
   existing invalidation points (project switch, profile generation,
   `scenesVersion` for Q&A, pick saves) and clear only the affected kind.
2. Reuse `blurbTranscripts` for `fetchTranscripts(videoID:)` in the three
   loaders; it is already invalidated on transcript edits.
3. Loading a tab must not set `isWizardRunning`: use a separate
   `isLoadingMiniFootage` flag for the stage label and leave the pickers
   enabled.
4. Tests: a per-kind cache test next to
   `ClipBuilderTests/Services/Wizard/MiniWizardTranscriptTests.swift`; drive Q&A ->
   Transcript -> Q&A live and confirm no reload (log line "Express:
   transcript ready" appears once).

## Do not touch

`scripts/release.sh`, `scripts/make_pkg.sh`, `build/performance-baseline*`,
`PRODUCT.md`, `DESIGN.md`. Do not change `RangeReviewView` layout (just
reworked on October 29, 2026, commit f123569).

## Acceptance

- Phase 0 timing lines show the before and after for: sidebar Sources ->
  Scenes -> Exports -> Sources, and Express Footage -> Transcript -> Q&A.
- Playing a 10,000-word transcript with Follow on for 60 s logs no `[hang]`.
- Debug `build-for-testing` green after every phase; the full suite runs in
  `scripts/release.sh`.
