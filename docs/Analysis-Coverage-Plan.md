# Analysis Coverage Plan

Date: October 9, 2026. Status: implemented October 9, 2026 (Codex), uncommitted. Verified: Debug build clean; AnalysisCoverage, PodcastAnalysis, AnalyzerStatic, SettingsCodable, AISettings suites 84/84. Analyze table and transcript sheet controls not yet exercised by hand.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).

## Problem

Some transcripts show a Q&A tab and others do not, and nothing tells the
user why. The Q&A tab exists only when the video has a non-ignored scene
tagged `q&a`, and those scenes are written by one path: the podcast pass
(`PodcastAnalysisService.analyze`), which Analyze runs only when the video's
type is Podcast at that moment, or when the "Podcast exchanges" stage is
rerun. Four situations therefore look identical:

1. The transcript came from a transcribe-only path (the transcript sheet's
   Re-transcribe, Builder prerequisites, the Wizard pipeline). No run, no
   exchanges.
2. The video was analyzed while its type was not Podcast. Auto-classification
   runs only when the type is unset and the video is at least 300 s; shorter
   recordings, hand-typed videos, and ones classified Interview or Other get
   visual analysis plus a transcript, never exchanges.
3. The podcast pass ran and found no exchange candidates (one speaker, no
   turns). Run and transcript exist, Q&A is empty.
4. The run predates a feature. Runs carry no pipeline version, so "analyzed
   before exchanges existed" and "analyzed, nothing found" are the same.

Interview recordings are question-and-answer footage too, and the Wizard,
Mini Wizard, B-roll and scene blurb code already treat Interview like
Podcast. Only the analysis gates do not.

## Decision

- **Interview joins the podcast pass.** `VideoType.usesPodcastPass` is true
  for `.podcast` and `.interview`. Every analysis gate uses it.
- **Runs carry a pipeline version.** A new optional `pipeline: Int?` on
  `AnalysisRunSettings`, stamped at run creation, lets the app state that a
  run is older than the current pipeline for its type.
- **Coverage is derived, not stored.** A pure `AnalysisCoverage` computes,
  from runs and scenes already in the store, what a video has and what is
  missing, with one plain-language reason and one action.
- **Status and action live on the card.** The Analyze table gets a Q&A
  glyph and an "update" glyph with a visible button; the transcript sheet
  explains a missing Q&A tab and offers the fix in place. No context-menu
  only entry points.

## Types

`Data/Models.swift`:

```swift
extension VideoType {
    /// Transcript-first analysis with speaker turns and Q&A exchanges.
    var usesPodcastPass: Bool { self == .podcast || self == .interview }
}
```

`Data/AIRunSettings.swift`: `var pipeline: Int?` on `AnalysisRunSettings`
(optional, synthesized decoding keeps old runs readable).

`Services/AnalysisPipeline.swift`, `nonisolated enum AnalysisPipeline`:

```swift
static let podcastPass = 1   // bump when the podcast pass gains a stage
static let visualPass = 1    // bump when visual analysis gains a stage
static func current(for type: VideoType?) -> Int
```

`Services/AnalysisCoverage.swift`, `nonisolated enum AnalysisCoverage`:

```swift
struct Report: Equatable {
    var qaCount: Int
    var hasTranscript: Bool
    var hasRun: Bool
    var latestPipeline: Int?          // nil for runs stamped before this plan
    var state: State
}
enum State: Equatable {
    case upToDate
    case needsAnalysis                // no run at all
    case transcriptOnly               // transcript rows, no run
    case missingExchanges             // usesPodcastPass, run exists, no q&a scenes
    case outdated(stage: String)      // latest run pipeline < current
    case untyped                      // type nil; podcast pass cannot be chosen
}
enum Action: Equatable { case analyze, runExchanges, setType }

static func report(video: VideoRecord, runs: [AnalysisRun], scenes: [SceneRecord],
                   transcriptCount: Int) -> Report
static func action(for state: State) -> Action?
static func message(for state: State, type: VideoType?) -> String
```

Rules, in order: no run and no transcript → `.needsAnalysis`; no run but
transcript rows → `.transcriptOnly`; type nil and duration under 300 s and
no q&a scenes → `.untyped`; `usesPodcastPass` and no q&a scenes →
`.missingExchanges`; latest run's `pipeline` (nil counts as 0) below
`AnalysisPipeline.current(for:)` → `.outdated`; else `.upToDate`. A run
that was explicitly rerun for exchanges and still has zero q&a scenes is
still `.missingExchanges`; the message says "No exchanges were found" when
`latestPipeline` is current, and "Exchanges were never grouped" otherwise.

Messages name the stage and the button, for example: "Exchanges were never
grouped for this interview. Run podcast exchanges to add the Q&A view." and
"This recording has no type, so Analyze cannot choose the podcast pass. Set
the type to Podcast or Interview, then analyze."

## Gates to change

Replace `video.type == .podcast` with `video.type?.usesPodcastPass == true`
(or the equivalent on the local `podcast` flag) at every analysis gate.
Known sites from grep on October 9: `App/AppStore+AITools.swift` ~L637,
`App/AppStore+Analysis.swift` L216, L273, L286, L672, `App/AppStore.swift`
~L2076, `Views/AIInfo/AIInfoSheet.swift` L36,
`Services/TranscriptionService.swift` L42, `Services/Analyzer.swift` L1018,
`Views/Builder/BuilderInspector.swift` L256. Grep again before finishing;
sites that already include `.interview` (Wizard, Mini Wizard, B-roll, scene
blurb) stay as they are. `AnalysisStage.forRole(_:podcast:)` callers pass
`usesPodcastPass`.

Stamp `pipeline` where runs are created: `Services/Analyzer.swift` ~L2110
(`AnalysisRunSettings(...)`) with `visualPass`, and the podcast run creation
in `Services/PodcastAnalysisService.swift` ~L73 with `podcastPass`. If the
podcast run does not write `settingsJSON` today, add the minimal settings
record with `pipeline` set; do not invent other fields.

## UI

**Analyze table** (`Views/AnalyzeView.swift`, glyph row ~L486-540). The
`TableSummary` gains `qaCounts: [Int64: Int]` from the scene index (count
of non-ignored scenes tagged `q&a` per video; extend `SceneIndex` if it has
no such counter) and `coverage: [Int64: AnalysisCoverage.Report]`. Two new
fixed-width slots after the transcript mark:

- Q&A glyph (`bubble.left.and.bubble.right`) with the count, secondary
  style, help "N Q&A exchanges", empty slot when zero.
- Update glyph (`arrow.triangle.2.circlepath`, orange) when the state is
  `.missingExchanges`, `.outdated`, `.transcriptOnly` or `.untyped`, help =
  `AnalysisCoverage.message`. Next to it a small bordered button labelled by
  the action: "Run exchanges" (calls `store.rerun(.exchanges, video:)`),
  "Analyze" (selects the video and opens the existing Analyze flow), or
  "Set type" (focuses the existing type picker at ~L767). `lineLimit(1)`,
  `fixedSize`. Disabled while `store.isAnalyzing`.

**Transcript sheet** (`Views/TranscriptSheet.swift`, header ~L371-400).
When `qaSections` is empty and the video `usesPodcastPass`, show under the
View picker one caption line with the coverage message and a "Run
exchanges" button (same call, closes nothing; the sheet refreshes through
the existing `refreshAll` path). When the type is nil, show the type picker
inline with caption "Podcast exchanges run only for videos typed Podcast or
Interview." Reuse the picker binding from `AnalyzeView` L767 by moving it
to a small shared view.

**Dispatch plan sheet** (`Views/DispatchPlanSheet.swift` ~L597). Append
one sentence to the existing explanation: "Exchanges run for videos typed
Podcast or Interview; other types get visual analysis."

## Not changed

- Classification thresholds (300 s, type nil only). Setting the type by hand
  is the path for short recordings; the UI now points at it.
- The podcast pass itself, exchange grouping, and the `q&a` tag.
- No database schema change, no `schemaVersion` bump: `pipeline` lives in
  the existing `settings_json` column.

## Tests

- `AnalysisCoverageTests` (new, under `ClipBuilderTests/Services`): every
  state in the rule order above, including interview with and without q&a
  scenes, a run with `pipeline` nil treated as 0, and `.untyped` only under
  300 s.
- `SettingsCodableTests` or `AISettingsTests`: `AnalysisRunSettings` decodes
  without `pipeline` and round-trips with it.
- `PodcastAnalysisTests`: a podcast run and an interview run both stamp
  `AnalysisPipeline.podcastPass`; an interview video takes the podcast
  branch in the stage-selection helper (extract the branch condition into a
  testable helper if it is inline today).
- `AnalyzerStaticTests`: a visual run stamps `visualPass`.

## Phases

1. Types, gates, stamping, `AnalysisCoverage`, tests. One commit.
2. Analyze table glyphs and button, transcript sheet caption and controls,
   dispatch plan sentence. One commit.
