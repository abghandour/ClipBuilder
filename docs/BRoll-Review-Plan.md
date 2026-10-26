# B-roll review for podcast and interview highlights

Date: October 25, 2026. Status: superseded the same day by docs/BRoll-Panel-Plan.md (the user rejected automatic B-roll); kept as history.

## Goal

When B-roll is on for a podcast or interview reel, the user sees exactly
where each B-roll cut lands against the transcript and for how long, and can
adjust, add, remove and replace cuts before rendering. The Wizard places cuts
where a fighter or a fight is mentioned. For any cut, the user can ask the AI
for three suitable scenes or search all scenes by hand.

Express gains a single B-roll switch. Full keeps its existing B-roll group.

## Rules that are not negotiable

- Only podcast and interview sources get this: the recording's `VideoType` is
  `.podcast` or `.interview`, or it has `podcast-exchange` scenes (the test
  `AppStore+Wizard` already uses for highlights).
- Cut times are stored on the **source recording's clock** (transcript time),
  never the reel's clock. Trimming a highlight keeps cuts on their words; a cut
  whose words fall outside the new range is dropped, one that straddles an edge
  is clamped.
- Nothing autoplays in the review. Items are labelled from the transcript or the
  scene name, never by an AI call. Word selection is press-and-drag, the same
  gesture as Express Transcript picks.
- The AI is called only when the user presses **Suggest** on a cut, or when the
  existing B-roll instructions are non-empty (current behaviour). A suggestion
  never blocks the UI: the card shows progress and the user can keep editing.
- The September 21, 2026 relevance rule stands for automatic placement: a scene
  from another recording qualifies only through a matched person or fight,
  never through topic keywords. A scene the user picks by search is the user's
  choice and is allowed.
- New Codable stored properties are Optional. Every action has a visible
  button; context menus only repeat them.

## Phase 1: data, mention matching, render, Express switch

1. **Stored cuts.** A `nonisolated struct BRollCut: Codable, Sendable, Equatable,
   Identifiable`: `id: UUID`, `start: Double`, `end: Double` (source-recording
   seconds), `sceneID: Int64`, `sceneOffset: Double` (seconds into the scene),
   `reason: String` (e.g. "Gane"), `origin` (`auto`, `ai`, `user`).
   `HighlightCandidate` gets `brollCuts: [BRollCut]?`: nil means "not planned
   yet", an empty array means "no B-roll". Persist it wherever candidate trims
   persist today (Express runs and the Full review request), Optional so old data
   decodes.
2. **Plan at find time.** After highlights are found (Full
   `findPodcastHighlights` callers and Express Highlights / Q&A / Transcript
   picks), when B-roll is on and the source qualifies, run the existing
   `PodcastHighlightBRollPlacement.plan` per candidate and store the result as
   `brollCuts`, converted to source time. Reaction-tile cuts (`.reaction`) stay
   automatic and are not shown as editable cards in this version; only scene
   cuts become `BRollCut`s.
3. **Mention matching (rules, no AI).** A pure `nonisolated enum
   BRollMentionMatcher` under `Services/` with tests:
   - Entities: people (`PersonRecord` names and the 4+ letter name tokens
     `mentionedPeople` already uses) and fights (`FightResearchRecord.fightLabel`
     split on " vs " into both fighters, plus `event`).
   - Input: the candidate's words with times. Output: mentions `(time, entity,
     matched text)`.
   - Candidate scenes per entity: scenes tagged `person:<key>`, and scenes of
     videos whose fight research label names the fighter (fight and recap
     videos first, then by score).
   - The deterministic planner places a cut just after each mention (up to 3 s,
     same spacing rules: not in the first 2 s, 2 s gaps, at most 40 % covered),
     then fills remaining windows the way it does today. The cut's `reason` is
     the matched text.
4. **Render uses stored cuts.** When `brollCuts` is non-nil, the render and the
   "build timeline" paths convert them to `PodcastHighlightBRollPlanner.Cut`
   and pass them as `plannedCuts` instead of planning again. The render
   fingerprint (`PodcastHighlightRenderKey`) includes the cuts, so an edited
   reel is not reused from cache.
5. **Express switch.** `MiniWizardSettings` gets `broll: Bool?` (nil = on). The
   settings card shows a "B-roll" toggle only when the chosen source qualifies.
   It sets `useBRoll` on the options Express builds.

## Phase 2: the B-roll review tab

In the existing review (Express `MiniHighlightReviewView` and Transcript picks
review; Full `PodcastHighlightReviewSheet`), a **Moments | B-roll** segmented
switch at the top when the run has B-roll on and the source qualifies. The
B-roll tab reuses the three-column layout (`TranscriptQAView`):

- **Left, transcript.** The selected highlight's words. Each cut's words get a
  coloured bar on their lines (the transcript-picks style); the trigger word is
  underlined. Press-and-drag selects words for a new cut.
- **Middle, player.** The highlight's source range. While the playhead is inside
  a cut, a muted second player shows the cut's scene at `sceneOffset` over the
  picture. A thin strip under the scrubber marks every cut; clicking one
  selects its card. No autoplay.
- **Right, cuts.** A highlight picker at the top when there are several, then
  one card per cut: scene thumbnail, `start–end`, length, reason, scene name,
  trim handles (the `RangeReviewItem` trim, snapping to words), **Replace** and
  **✕ Remove** buttons. **+ Add B-roll** above the list adds a cut over the
  selected words and opens Replace. A footer reads "18 % covered · max 40 %";
  a card that breaks a spacing rule shows a small warning. Nothing is blocked.

Edits write back to the candidate's `brollCuts`, so Render and the Builder get
exactly what the review shows.

## Phase 3: Replace popover, AI suggestions and search

The Replace popover lists, top to bottom:

1. **Suggested by AI**: a **Suggest** button. It sends the cut's words, the
   sentence around them, the highlight title and the allowed scene pool (same
   cap of 60, mention matches first) to a new one-shot AI task
   `.brollSuggest` (`AICatalog` label "B-roll suggestions", default provider and
   chain like `.broll`). The response is three scene IDs with a short reason
   each, parsed with `AIResponseParser.jsonObject` and validated against the
   pool. Results show as three thumbnails with their reasons. The call runs in
   a task owned by the review model, cancels when the review closes, and shows
   progress on the card.
2. **Matches**: scenes for the cut's mention, from the matcher.
3. **Search**: a field that filters all active project scenes locally by scene
   name, tags, people, narrative and video filename.

Picking any scene swaps it into the cut and keeps the timing; `origin` becomes
`ai` or `user`.

## Tests

- `BRollMentionMatcherTests`: names and fight labels at word times, 4+ letter
  token rule, both fighters from "A vs B", no match on topic words.
- Planner: a cut lands after a mention, spacing and coverage rules hold.
- Clock mapping: cuts survive a trim on their words, drop outside, clamp at
  edges; conversion to `Cut` for a whole and a sub-cut candidate.
- Render key changes when a cut changes.
- `.brollSuggest` response parsing and pool validation.
- `MiniWizardSettings` decodes old JSON without `broll`.
