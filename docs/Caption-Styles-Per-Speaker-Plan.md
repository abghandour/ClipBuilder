# Caption style per speaker

Date: October 23, 2026. Status: implemented by Codex; Claude to verify

## Goal

In the wizard's Captions section (Express `MiniSettingsCard` Overlays tab and
the full wizard `WizardView+Look`), under "Caption style", the user can give
each person who speaks in the footage their own caption style. A person with
no choice follows the run's Caption style. The render, the Builder render and
the Express preview all honour it.

## Data

- `BrandProfile.personCaptionStyles: [String: String]?` — person key →
  `NamedCaptionStyle.id.uuidString`. Optional so existing profile JSON and
  Team Sync documents decode unchanged (`BrandProfile` uses synthesized
  decoding; add the property and nothing else). Helper:
  `func captionStyle(forPerson key: String, runStyleID: String?) -> CaptionStyle`
  returns the person's named style when the id resolves, else
  `captionStyle(id: runStyleID)`. Also
  `func speakerCaptionStyles(runStyleID: String?) -> [String: CaptionStyle]`:
  only the people whose resolved style differs from the run style (an entry
  pointing at a deleted style is dropped).
- No change to `WizardOptions` or `MiniWizardSettings`: the mapping is a
  profile-wide person attribute, like a person's tag text and tag position
  (see `NameTagPeopleEditor`), saved with `store.saveActiveProfile()`.

## Speaker identity

`CaptionSpeakerColors.color(for:turns:rows:)` already finds the speaker of a
segment. Split it:

- `static func speakerKey(for segment: TranscriptSegment, turns: [SpeakerTurn], rows: [TranscriptRow]) -> String?`
  returns the existing internal key (`"person:<key>"`, `"feed:<n>"`,
  `"cluster:<n>"`; nil for `.unknown` attribution or no turns).
- `color(...)` uses it unchanged in behaviour.
- `static func personKey(_ speakerKey: String?) -> String?` strips the
  `person:` prefix, nil otherwise. Only person-attributed speech can take a
  person's style.

## Rendering

`CaptionOverlayPlan`:

- `Page` gains `styleID: String?` (nil = run style). `Raster` gains
  `styleID: String?` (part of its `Hashable`, so the PNG cache never mixes
  styles).
- New `nonisolated struct CaptionRendererSet: Sendable`:
  `base: CaptionRenderer`, `perSpeaker: [String: CaptionRenderer]` keyed by
  person key, `init(base:speakerStyles:[String: CaptionStyle])` building a
  renderer per style with the base's video size, safe area and safeAreaOnly
  (add whatever `CaptionRenderer` properties are needed to copy them),
  `func renderer(styleID: String?) -> CaptionRenderer`,
  `func renderer(for segment:turns:rows:) -> (CaptionRenderer, styleID: String?)`
  where `styleID` is the person key when that person has a renderer.
  `var usesSpeakers: Bool { !perSpeaker.isEmpty }`.
- `pages(segments:renderer:…)` keeps its signature and forwards to a new
  `pages(segments:renderers: CaptionRendererSet, …)`: per segment pick the
  renderer (so words per page, uppercase and two-row fitting follow that
  style), colour from that renderer's `style.resolvedSpeakerColors`, and set
  `Page.styleID`.
- `plan(pages:style:)` keeps its signature and takes an optional
  `styles: [String: CaptionStyle] = [:]`; per page `let style = page.styleID.flatMap { styles[$0] } ?? style`
  for emphasis, emoji, reveal and animation decisions; the raster carries
  the page's `styleID`.
- `CaptionPNGCache` holds a `CaptionRendererSet` (keep the
  `init(renderer:directory:)` convenience) and renders each raster with
  `renderers.renderer(styleID: raster.styleID)`; add
  `func position(for rendered:, raster:, positionOverride:)` or expose
  `renderer(styleID:)` so callers position with the right style.
- Turns and rows are fetched when `style.resolvedSpeakerColors` OR the
  renderer set `usesSpeakers` (today only for colours).

Call sites (all three must change together):

- `WizardEngine` clip render (~4158–4200): build
  `CaptionRendererSet(base:speakerStyles: profile.speakerCaptionStyles(runStyleID: options.captionStyleID))`,
  pass `styles:` to `plan`, position with the raster's renderer.
- `MultitrackRenderer` (~517–519 and ~1584–1600): same with
  `profile.speakerCaptionStyles(runStyleID: nil)` (the Builder renders the
  profile default as the run style). `RenderSegmentKey` gains
  `speakerCaptionStyles: [String: CaptionStyle]` (encode sorted by key) so a
  per-speaker change invalidates cached segments; the gap-segment key passes
  `[:]`.
- `WizardPreviewComposite` (~147–170): resolve the preview moment's speaker
  with `CaptionSpeakerColors.speakerKey` from the snapshot's turns/rows
  (`input` already carries what the preview needs for speaker colours; add
  turns/rows to the input if it does not) and render with that person's
  style when one is set. `PreviewKey` / `WizardPreviewColumn.ContentKey`
  include `profile.personCaptionStyles` (via the profile version they
  already key on; verify a change to the mapping refreshes the preview and
  add the mapping to the key if not).
- `PodcastRecipeTimeline` / `WizardPodcastTimeline` / `PodcastHighlightTimeline`
  only if they build captions themselves (search `CaptionOverlayPlan.pages`);
  otherwise untouched.

## UI

`Views/CaptionSpeakerStylesEditor.swift` (new), modelled on
`NameTagPeopleEditor`: `people: [PersonRecord]?`, `videoIDs: [Int64]?`,
`runStyleID: String?`, `profile: BrandProfile`. Lists the run's people
(roster keys from `database.fetchVideoPeople(videoID:)` like the name-tag
editor, hidden people excluded, sorted by key), one row per person: avatar
(`PersonFaceAvatar`, the People-page picture), name, and a menu picker whose
first item is "Run style" (nil) followed by `profile.captionStyles`; picking
writes `store.activeProfile.personCaptionStyles[key]` (nil removes the key)
and calls `store.saveActiveProfile()`. Caption under the list:
"People without a choice use the Caption style above. Choices are saved
with the profile and apply to every run." Shown under the Caption style row
in `MiniSettingsCard` (Express: `people: nil, videoIDs: [run.video.id]`) and
`WizardView+Look` (the same `people`/`videoIDs` the name-tag controls pass),
indented with `.formDependent()` / the Mini dependent-row pattern, only
while captions are on. Rows need a visible control; no context menus.

## Tests

- `CaptionStyleTests` or new `CaptionSpeakerStylesTests`:
  `speakerCaptionStyles` drops entries equal to the run style and entries
  pointing at deleted styles; `captionStyle(forPerson:runStyleID:)`
  fallbacks; `BrandProfile` round trip with the mapping; old JSON without it
  decodes.
- `CaptionSpeakerColorsTests`: `speakerKey` matches what `color` chooses
  (person attribution wins, `.unknown` nil, first overlapping turn).
- `CaptionOverlayPlanTests`: two segments by two people with different
  words-per-page styles produce pages paged by their own style, rasters
  carry the styleID, and `plan` applies the per-page emphasis setting.
- `CaptionRendererTests` (pixel, via `CaptionPNGCache`): the same text
  rendered through a set with a per-speaker colour style differs from the
  base and the cache returns distinct PNGs for equal text with different
  styleIDs.
- `RenderSegmentCacheTests`: key changes when `speakerCaptionStyles`
  changes.
- `WizardPreviewCompositeTests`: a preview moment inside a person's turn
  renders with that person's style (compare against a direct render).

## Verification (Claude)

Debug build; the suites above; live in Express › Overlays: the people list
appears under Caption style, picking a style for the interviewer changes
the preview while his words show, and a render carries both styles.
