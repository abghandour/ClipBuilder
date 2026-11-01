# Local teaching queue

Date: October 31, 2026. Status: implemented October 31, 2026 (Claude), not yet driven live. v1 leaves
`taste` nil: scoring it per reel needs decoded frames. From the October 31
product review, item 10.

## Goal

Instead of grading every reel, show the few reels and sibling pairs where the
on-device outcome model, the critic, and existing human judgments disagree
most. Each item says which sources disagree and which model the answer
informs. Judging reuses the review and comparison sheets. A Re-evaluate button
retrains the informed models; the Use toggle stays gated by eligibility.

## Design

- `ClipBuilder/Services/Models/TeachingQueue.swift` (new, `nonisolated enum`).
  - `struct Signals: Sendable, Hashable` with `reelID: Int64`, `batchID:
    String?`, `outcome: Double?` (mean predicted lift), `ranker: Double?`,
    `taste: Double?`, `criticScore: Int?`, `criticForecast: Int?`,
    `humanVerdict: Int?`, `hasPreference: Bool` (any wizard_preferences row).
  - `enum Source: String, Codable { outcome, ranker, taste, critic }`.
  - `struct Item: Identifiable, Sendable, Hashable` with `kind`
    (`.reel(Int64)` or `.pair(Int64, Int64)`), `disagreement: Double` (0...1),
    `disagreeing: [Source]`, `informs: [ReelModelItem]`, `summary: String`.
  - `static func rank(signals: [Signals], limit: Int = 5) -> [Item]`.
    Normalize each source to a percentile rank within the pool (nil stays
    nil). Reel disagreement = max pairwise gap between available sources;
    skip reels with a human verdict. Pair: two siblings in the same batch that
    two sources order oppositely, skipped when either already has a
    preference; disagreement = mean of the two rank gaps. `informs`
    follows where the answer is consumed: a pair pick (wizard_preferences)
    informs the outcome model's evaluation (`preferenceAgreement`); a reel
    verdict (generation_reviews) informs no on-device model, only the
    wizard's lessons, and its summary says so. Re-evaluate counts pair
    answers only. Sort by disagreement desc, cap at `limit`.
- Orchestration `AppStore+TeachingQueue.swift` (new): `teachingQueue:
  [TeachingQueue.Item]`, `refreshTeachingQueue()` loads
  `fetchGeneratedVideos`, traits, critique JSON, the outcome predictor if
  eligible (`ReelModelStore.predictor`), per-reel ranker/taste means over the
  plan clips' scenes, reviews and preferences, builds `Signals` off the main
  actor through `AppJobWork.run`, then ranks.
- UI: `Views/TeachingQueueSection.swift`, a `GroupBox("Teaching queue")`
  placed after the trained-models grid in `ReelModelsLearnedSection`: a
  Refresh button, rows with the reel name (or "A vs B"), the disagreeing
  sources, "informs: …", and a Judge button (opens `ReviewSheet(video:)` or
  sets `pendingComparison`), plus a Re-evaluate button that calls
  `startModelEvaluation` for each informed model with a pending answer.
- Tests: `ClipBuilderTests/Services/Models/TeachingQueueTests.swift`:
  planted disagreement ranks first, judged reels skipped, pair rule with
  opposite ordering, pairs with a preference skipped, limit respected, nil
  sources ignored.
