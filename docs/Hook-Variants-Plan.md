# Controlled hook comparisons

Date: October 31, 2026. Status: implementing (Claude). From the October 31
product review, item 8.

## Goal

From one Builder timeline, make variants that differ only in the opening
(first clip, or the opening text overlay), render them, pick a preference in
the existing comparison sheet, and when variants were published, show their
Instagram stats side by side with a fixed caveat that organic posts are not a
randomized test.

## Design

- `ClipBuilder/Services/HookVariantBuilder.swift` (new, `nonisolated enum`).
  - `struct HookAlternative: Codable, Sendable, Hashable` with `label`,
    `mode` (`firstClip`, `openingText`), `sceneID: Int64?` (which existing
    clip's footage becomes the cold open), `overlayText: String?`,
    `reason: String?`.
  - `static func variants(base: TimelineDocument, alternatives:
    [HookAlternative], openingWindow: Double = 3) -> [(label: String, document:
    TimelineDocument)]`.
  - `firstClip` is a cold open (`coldOpen(sceneID:in:)`): the base's opener
    (first track-0 main clip) is replaced by a NEW clip copied from the
    track-0 clip with that scene: same scene and video file, same
    `sourceStart`, duration `min(base opener, that clip, 3 s)`, fresh `uid`
    and `originKey`. The body is exactly `base` track-0 main clips
    `.dropFirst()` in order, unchanged apart from every `startTime` moving by
    the same `newOpener.duration - oldOpener.duration`. Text and image
    overlays close up the same stretch (`TimelineCutMap`); music that plays
    into the body shifts with it and is head-trimmed (`sourceOffset`) so the
    song stays in step with the body.
  - Dependent-track restriction (`allowsClipAlternatives`): a document with
    any clip on a track other than 0, B-roll or bumpers, overlay blocks, crop
    blocks, dub lines, or source-bound stat overlays gets no `firstClip`
    variants: `variants` and `parseAlternatives` skip them and the prompt
    (`allowClipAlternatives: false`) asks for `opening_text` only.
  - `openingText`: replace the text of the earliest plain overlay starting
    before `openingWindow` (name tags, meaning `design == "tag"` or a
    `tagStyle`, and stat cards are never touched), or insert one at
    0...2.5 s when none. An overlay that runs past `openingWindow` is split:
    the opening piece gets `overlayText`, the rest keeps its text (new uid).
- `AITask.hooks` (raw `"hooks"`): prompt builder in `HookVariantBuilder.prompt
  (document:scenes:allowClipAlternatives:)` lists the clips (index, scene
  blurb, duration) and the current opening text, asks for 3 alternatives as JSON
  `{"alternatives":[{"label","mode","scene_id","overlay_text","reason"}]}`,
  parsed with `AIResponseParser.jsonObject`. `AICatalog` entries (label
  "Hook alternatives", default provider same as `.wizard`, chain same as
  `.captions`). `AITaskRegistryTests` must stay green.
- Storage: `generated_videos.variant_group_id TEXT`, `generated_videos.hook_label
  TEXT` (migrations), Optional fields on `GeneratedVideoRecord`, mapped in
  insert/select. `wizard_preferences.chosen_label TEXT`, `rejected_label TEXT`
  (Optional). `addPreference` takes optional labels; the "A/B Choices" prompt
  block in `WizardEngine` renders `CHOSE "<label>" OVER "<label>" hook` for
  labelled rows.
- Job: `AppJobKind.hookVariants`. `AppStore.startHookVariants(timelineID:)`
  (`App/AppStore+HookVariants.swift`, new) runs the AI call, builds the
  variants, renders each through `MultitrackRenderer.render` with a shared
  `batchID = variantGroupID` and the base (label "Original") included, stores
  `hookLabel`, and then `queueComparisons` so the comparison sheet appears.
  `ComparisonSheet` shows `hookLabel` when present instead of "Variation N".
  Review sheet case in `AppJobReviewSheet`.
- Readout: `Views/HookVariantReadout.swift`, reached from the Library card of
  any reel with a `variantGroupID` ("Compare hooks" button): rows per label
  with views, reach, likes, saves, avg watch time (dashes when unpublished),
  the preference pick if any, and the fixed caveat text. No winner is
  declared.
- Builder entry: toolbar button "Hook variants…" in the Builder (visible,
  `lineLimit(1)` + `fixedSize`) which starts the job for the current timeline.
- Tests: `ClipBuilderTests/Services/HookVariantBuilderTests.swift`: firstClip
  cold open, body equal across variants apart from a constant shift, no
  cold open with a track-1 clip, openingText split and name tags untouched,
  openingText replaces or inserts, prompt JSON parse round-trip of a sample response.
