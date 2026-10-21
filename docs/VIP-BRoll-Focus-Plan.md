# VIP B-Roll Focus: follow the talker, break to the VIPs

Date: October 21, 2026. Status: implemented, Debug build passes, suites green; live verification pending.

## Goal

A new Camera focus, "VIP B-Roll Focus". The picture follows whoever is
talking (the asker, the host, or a VIP), as "Talker full screen" does. At
intervals it breaks to a VIP as B-roll: the VIP's own feed when the
recording has one, otherwise VIP footage from the library. Breaks land on
moments where the VIP is expressive (a laugh, a nod, a gesture) when the
on-device scorer finds them, and are spaced evenly otherwise. Every break
lasts a few seconds so the viewer never loses orientation, and the talker's
audio never changes. Requested by the user on October 21, 2026, after VIP
focus (docs/VIP-People-Plan.md).

## Where we stand (uncommitted VIP work in the tree)

- `CropRecipe.Kind.vip` with `CropRecipeSubject.vip` and
  `VIPRecipePlanning` (`Services/VIPRecipePlanning.swift`): VIP tiles by
  person key or portrait position, feed events, tracking spans; `BuilderStore`
  composes a VIP plan as per-feed speech-precise clips.
- B-roll: `WizardPodcastBRoll.adding` runs for `highlightFraming == .vip`
  without instructions; `VIPBRollWindows.windows` / `needingFootage` give the
  non-VIP-speech spans; `PodcastHighlightBRollPlanner.vipPlan` fills them
  with `.reaction(tile:)` then VIP scenes; `Cut.vipWindow` relaxes the 2 s
  gap inside one window; `PodcastHighlightTimeline.add(cuts:)` places
  cutaways with `coverAll: true`.
- Talker base: `CropRecipePlanner.plan(.talker)` and the podcast timeline.
- Expression signal: `VisualSpeechActivity.measure(url:tiles:start:duration:)`
  (`Services/VisualSpeechActivity.swift`) already decodes small frames at
  about 8 per second per tile and compares a mouth luminance patch between
  frames; `luminancePatch(_:region:grid:)` is reusable for any region.
  Vision is imported there and in `PodcastAnalysisService`.
- Preview: `WizardPreviewFraming` previews any kind through the planner.

## Rules

- The base picture is the talker plan unchanged; breaks are cutaways on the
  cutaway track, so the audio and the talker clip stay as they are.
- A break lasts 2.5 to 4 s, never less; the first break starts after at least
  3 s; breaks are at least 4 s apart; breaks cover at most 35 % of the clip;
  a break never cuts across a speaker change in its last second (end it at
  the change instead, or drop it when that leaves under 2.5 s).
- A break shows the VIP only while someone else is talking, or while the VIP
  is silent. During the VIP's own speech the talker base already shows them.
- Expression scoring is on-device, bounded (about 8 samples per second on
  small frames, like `VisualSpeechActivity`), runs off the main actor, and is
  optional: with no peaks above the floor, breaks are spaced evenly through
  the eligible spans. The log says which ("VIP B-roll: 3 breaks on expressive
  moments" vs "evenly spaced").
- Pure scheduling (`VIPBRollSchedule`) and pure scoring maths
  (`VIPExpressionScore`) are `nonisolated` with tests; frame decoding stays in
  one `measure` function next to `VisualSpeechActivity`.

## Model

- `CropRecipe.Kind.vipBRoll = "vip_broll"`, name "VIP B-Roll Focus",
  summary "Follow the talker, with short breaks to the VIPs on their
  expressive moments." `layoutName` → full screen; `defaultSlots` →
  `[.talker]` (the planner treats it exactly as `.talker`; the breaks are
  B-roll). `WizardCameraFocus.summary` and the pickers follow from
  `Kind.allCases`. `CameraFocusChooser.allowedLayouts` offers it under the
  same `hasVIP` gate as `.vip`; its prompt line explains the difference
  (continuous VIP feed vs. talker with VIP breaks).

## Expression scoring: `VIPExpression`

`Services/VIPExpression.swift`:

```swift
nonisolated enum VIPExpression {
    struct Track: Sendable { var tile: Int; var samples: [(time: Double, score: Double)] }
    /// Per VIP tile, a motion score per sample: mean absolute luminance change of
    /// the face patch (upper 60 % of the tile's face box, else the tile's
    /// centre third) between consecutive frames, normalised by the tile's
    /// median change over the window so a fidgety feed does not win by default.
    static func measure(url: URL, tiles: [PodcastTile], roster: [VideoPersonRecord],
                        start: Double, duration: Double) async -> [Track]
    /// Peaks: local maxima above 1.8x the median with at least 4 s between
    /// them, as source times.
    static func peaks(_ track: Track, minimumGap: Double = 4) -> [Double]
}
```

`measure` reuses `VisualSpeechActivity.luminancePatch` and its frame reader
(factor the AVAssetReader loop into a shared `SmallFrameReader` if that is
cleaner than calling into `VisualSpeechActivity`). It only decodes the
clip's source span. Library B-roll scenes (other recordings) are not scored;
they are used in the order `PodcastHighlightBRollPlanner.vipPlan` already
uses.

## Scheduling: `VIPBRollSchedule`

`Services/VIPBRollSchedule.swift`, pure:

```swift
nonisolated enum VIPBRollSchedule {
    struct Break: Sendable, Equatable { var start: Double; var duration: Double; var tile: Int?; var expressive: Bool }
    static let minimum = 2.5, maximum = 4.0, lead = 3.0, gap = 4.0, share = 0.35
    static func breaks(range: ClosedRange<Double>, eligible: [ClosedRange<Double>],
                       peaks: [(time: Double, tile: Int)], speakerChanges: [Double]) -> [Break]
}
```

- `eligible` = `VIPBRollWindows.windows(turns:vipKeys:range:)` (non-VIP
  speech) plus VIP silence inside the range, clipped to `[range.lowerBound +
  lead, range.upperBound]`.
- Expressive breaks first: for each peak inside an eligible span, a break of
  `maximum` centred on the peak, clipped to the span and trimmed at a speaker
  change in its last second; keep it when ≥ `minimum`; enforce `gap` and
  `share`, taking peaks in descending score order.
- If no expressive break survives, evenly spaced breaks: one per
  `max(10 s, eligible length / 3)` of eligible time, `3 s` long, same limits.
- Returns breaks on the source clock, sorted.

## Planner and engine wiring

- `PodcastHighlightBRollPlanner.vipBRollPlan(candidate:sources:turns:tiles:
  scenes:breaks:)`: each `Break` with a `tile` becomes
  `Cut(source: .reaction(tile:), sourceStart: break.start, start: break.start
  - candidate.sourceStart, duration:)`; a break without a tile (single-feed
  recording) takes the next VIP scene from `sources` (same recording first)
  with `duration` clipped to the scene; reason "VIP B-roll · expressive
  moment" or "VIP B-roll · scheduled break". `Cut.vipWindow` is nil (normal
  spacing applies; the schedule already spaced them).
- `WizardPodcastBRoll`: when `highlightFraming == .vipBRoll`, measure
  expressions for the VIP tiles over each span (`VIPExpression.measure`),
  build the schedule, and use `vipBRollPlan`; no AI placement call and no
  instructions needed. Cache key includes the kind. Log the break count and
  mode.
- `PodcastHighlightBRollPlacement`: shares the on-device scheduling path with
  `WizardPodcastBRoll` so Express highlights also use it without an AI call.
  Peak inputs are ordered by score before entering `VIPBRollSchedule`.
- `WizardEngine`: the B-roll trigger that already covers `.vip` also covers
  `.vipBRoll`; `plan.framing` from the AI chooser may be `.vipBRoll`.
- Timeline: cuts go through `PodcastHighlightTimeline.add` unchanged.
- Preview: nothing to add; the first frame is the talker.

## Tests

- `VIPBRollScheduleTests`: lead and gap respected; a break never shorter than
  2.5 s; trimmed at a speaker change; share cap; evenly spaced fallback when
  no peaks; peaks outside eligible spans ignored; two peaks 2 s apart yield
  one break.
- `VIPExpressionTests`: synthetic sample tracks → `peaks` picks the local
  maxima above 1.8x median with the gap; a flat track yields none.
- `PodcastHighlightBRollPlannerTests`: `vipBRollPlan` maps breaks to reaction
  cuts on a two-tile recording and to VIP scenes on a single-feed one.
- `CameraFocusChooserTests`: `vip_broll` offered only with a VIP.
- `CropRecipePlannerTests`: `.vipBRoll` plans like `.talker`.

## Verification

Debug build; live: a two-person podcast with the guest as VIP, Camera focus
VIP B-Roll Focus, render a highlight: the host stays on screen while asking,
the guest appears for 2.5 to 4 s at a time on laughs or nods, never two
breaks within 4 s, and the audio is continuous. Job log names the mode.
