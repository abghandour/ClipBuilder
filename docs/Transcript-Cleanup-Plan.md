# Word-level transcript cleanup and retake review

Date: October 31, 2026. Status: implemented, compile-checked; tests not run (Claude). From the October 31
product review, item 6.

## Goal

The transcript analysis proposes word-level removals (filler words, stutters,
false starts) and repeated takes (keep the last take), each reviewable in the
existing Proposed Cleanup Cuts list, auditionable, and applicable to a Builder
timeline as cuts. Cuts snap to word boundaries and keep a minimum gap so
breaths are not clipped.

## Design

- `ClipBuilder/Services/TranscriptCleanupProposer.swift` (new,
  `nonisolated enum`).
  - `struct Options: Sendable` with `fillers: Set<String>` (um, uh, erm, hmm,
    "you know", "i mean", plus "like" only when preceded and followed by a
    pause ≥ 0.2 s), `minGap: Double = 0.25`, `retakeWindow: Double = 20`,
    `retakeSimilarity: Double = 0.8`, `maxRetakeWords: Int = 40`.
  - `struct CleanupProposal: Sendable, Hashable` with `kind`
    (`filler`, `repeatWord`, `falseStart`, `retake`), `rowID: Int64`,
    `wordRange: Range<Int>`, `startTime`, `endTime`, `reason`.
  - `static func propose(rows: [TranscriptRow], options: Options = .init())
    -> [CleanupProposal]`.
  - Rules: filler = a normalized token (or bigram) in the set; repeatWord =
    adjacent equal normalized tokens (drop the first); falseStart = a fragment
    of ≤ 3 words ending in a pause ≥ 0.4 s whose first token equals the next
    fragment's first token; retake = two sentences (rows, or row spans split on
    terminal punctuation) within `retakeWindow` seconds whose token Jaccard ≥
    `retakeSimilarity` and length ≤ `maxRetakeWords`, propose removing the
    earlier one. Trim each cut so the remaining gap on each side is at least
    `minGap`; drop a cut that would become shorter than 0.05 s. Never cut
    inside a word.
  - `static func similarity(_ a: [String], _ b: [String]) -> Double` (Jaccard on
    normalized tokens) lives here too.
- `EditProposal.Kind` gains `repeatWord` and `retake`. `CleanupCutPolicy` leaves
  both pending. `Database.replaceTranscriptFeatures` includes the new kinds in
  both `IN (...)` lists so re-analysis replaces them and keeps decisions.
- `AppStore+Jobs.swift` `startTranscriptAnalysis`: after the existing analyzer,
  run the proposer over the transcript rows (with words) and append the
  proposals mapped to `EditProposal` (reason prefixed by the kind).
- `TranscriptToolsSheet`: each cut row shows a kind badge; an Audition button
  plays `[start-1.0, start]` then seeks to `end` and plays `[end, end+1.0]`
  using a small `CutAuditionPlayback` wrapper around AVPlayer (new file
  `Views/CutAuditionPlayback.swift`), one player shared by the sheet.
- Apply to timeline: `TimelineDocument.applyingCuts(_ ranges: [ClosedRange<
  Double>], videoID:)` in `Data/TimelineModels.swift` splits every clip of that
  video with `subtracting`, ripples `startTime` so pieces abut, and drops
  pieces shorter than 0.1 s. `BuilderStore.applyAcceptedCleanupCuts()` reads
  accepted proposals for the clips' videos and applies them, exposed as a
  "Apply cleanup cuts" button in the Builder clip inspector (visible control)
  that shows how many accepted cuts fall inside the timeline's clips.
- Tests: `ClipBuilderTests/Services/TranscriptCleanupProposerTests.swift` with
  a `words(_:start:step:)` helper: filler, bigram filler, conditional "like",
  stutter, false start, retake keeps the last, min-gap trimming, word-boundary
  snapping, no cut below 0.05 s. `TimelineDocument.applyingCuts` tests in
  `ClipBuilderTests/Data/`: split + ripple, drops tiny pieces, other videos
  untouched.
