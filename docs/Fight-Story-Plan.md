# Evidence-linked fight stories

Date: October 31, 2026. Status: implemented November 1, 2026 (Claude);
compiles, tests written but not run, not driven live. From the October 31
product review, item 5.

## Goal

Assemble one timeline from an interview claim (a transcript pick), a fight
sequence (fight picks from a fight video), and an outcome card (copy from
fight research and outcome records, optional strike stat card). Every clip and
card keeps provenance back to its transcript range, fight events, or research
record, and the result opens in the Builder.

## Design

- `Data/TimelineModels.swift`: `struct StoryProvenance: Codable, Sendable,
  Equatable, Hashable` with `kind` (`transcript`, `fightAction`, `outcome`,
  `research`), `videoID: Int64?`, `sourceStart`, `sourceEnd: Double?`,
  `transcriptPickID`, `fightPickID: Int64?`, `eventIDs: [Int64]?`,
  `researchVideoID: Int64?`, `label: String?`. `TimelineClip.provenance:
  StoryProvenance?` and `TextOverlayItem.provenance: StoryProvenance?`,
  Optional, `decodeIfPresent`, included in equality and CodingKeys.
- `ClipBuilder/Services/Wizard/FightStoryBuilder.swift` (new, `nonisolated
  enum`).
  - `struct StoryCardCopy: Codable, Sendable, Equatable` with `kicker`,
    `headline`, `subline: String?`.
  - `struct Input: Sendable` with `claim: TranscriptPick`, `claimScene:
    SceneRecord`, `claimVideo: VideoRecord`, `fight: [FightPick]`,
    `fightScenes: [Int64: SceneRecord]`, `fightVideo: VideoRecord`,
    `outcome: FightOutcome?`, `research: FightResearchRecord?`, `card:
    StoryCardCopy`, `stat: StrikeStatPayload?`, `cardDuration: Double = 2.5`.
  - `static func build(_ input: Input, renderSettings: RenderSettings) ->
    TimelineDocument`: claim clip first (track 0), fight clips in pick order,
    then a `cardDuration` gap at the end with a `TextOverlayItem` (design
    "hero", kicker + headline, `stat` set when provided) over it. Provenance
    stamped on every clip and the card. Clip `startTime`s rippled.
  - `static func fallbackCard(outcome:research:fightLabel:) -> StoryCardCopy`
    from `FightOutcome.method/round` and `research.summary.story.hook_line`
    when the AI copy is unavailable.
- `AITask.storyCard` (raw `"story_card"`): prompt builder
  `FightStoryBuilder.prompt(claimText:fightLabel:outcome:research:)` asks for
  `{"kicker","headline","subline"}`; `AICatalog` entries copied from
  `tagText`; `AITaskRegistryTests` green.
- Job and store: `App/AppStore+FightStory.swift` (new):
  `startFightStory(claimPickID:fightVideoID:fightPickIDs:includeStats:)`
  loads picks, scenes, videos, outcome, research, optional strike stats
  (reuse the loading pattern from `AppStore+StrikeStats.swift`), calls the AI
  for the card copy (falls back to `fallbackCard`), builds the document, and
  `createTimeline(named: "<fight label> story", document:)` opens it in the
  Builder. `AppJobKind.fightStory` with a review sheet case showing the card
  copy and a Open in Builder button.
- UI: `Views/FightStorySheet.swift`: a claim picker (transcript picks of the
  project's interview videos, text preview), a fight video picker and its
  picks (multi-select, in order), a "Include strike stats" toggle, a card copy
  preview (editable fields), and Build. Launched from a visible "Fight story…"
  button on the Express footage card row next to Fight metrics
  (`MiniFootageCard`) and from the Analyze view next to Fight research.
- Tests: `ClipBuilderTests/Services/Wizard/FightStoryBuilderTests.swift`:
  order and ripple, provenance on each clip and the card, card gap length,
  stat passthrough, fallback card from outcome, round-trip of a
  `TimelineDocument` with provenance through JSON (older JSON without the
  key still decodes).

## Implementation notes

- The renderer's output ends at the last clip (`totalDuration` is the max
  clip end), so a bare trailing gap never renders. The card sits over a
  `cardDuration` backdrop clip of the fight video, dimmed with the
  `brightness` effect, taken from footage outside every pick
  (`FightStoryBuilder.backdropPlan`: right after the last pick, else the
  longest free stretch, else the last pick's tail, trimmed off that pick's
  clip when the pick is at least `2 * cardDuration` long; a shorter pick
  keeps its full clip, the tail overlaps it, and the stat card is omitted).
  Outside the shown picks matters because a stat card shows on every clip
  covering its source time.
- The strike stat card is a second overlay (stat cards render their own
  layout and bind to a source moment), bound to the backdrop's first frame.
- Story clips reference scenes from `Database.storyScene` (exact range on the
  active run, reused when present, else a new scene tagged `fight-story`).
- The job saves the timeline without opening it; the review sheet's Open in
  Builder opens it.
- The sheet's card fields are optional: an empty headline asks the model
  (`story_card`), falling back to `fallbackCard`.
