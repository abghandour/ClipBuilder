# Caption reveal: words appear as they are spoken

Date: October 20, 2026. Status: implemented, Debug build passes, reviewed; live verification pending.

## Goal

A caption style option that hides each word of a page until it is spoken, so
a multi-word page fills in word by word. The caption re-centres around the
words shown so far (the box grows as words arrive), nothing shows before the
page's first word, silence inside a page keeps the words already shown, and
the user chooses whether each new word gets the page's entrance motion or
only the page does. Decided with the user on October 20, 2026.

## Where we stand

- `CaptionOverlayPlan.plan` turns pages into `Raster`s (text, activeIndex,
  emphasis, colour, animation frame) with time windows. With Highlight off a
  page is one raster; with Highlight on `CaptionWordStates.states` gives one
  state per spoken word plus unlit silence states, and the first state gets
  `CaptionAnimation.frames` for the page entrance. Over `inputLimit` (300)
  overlays the plan falls back to one static raster per page
  (`usedPageFallback`), merging pages when even that is too many.
- `CaptionRenderer.render(text:activeIndex:emphasis:…)` lays out and draws
  the text it is given and `position(for:)` anchors the resulting box, so a
  raster with fewer words is already centred and anchored on its own.
- `CaptionPreviewImage` and the Captions library's animated preview use the
  same plan. Builder and Wizard overlay the rasters with ffmpeg.

## Rules

- New `CaptionStyle` properties are Optional with resolved accessors; old
  JSON decodes and renders unchanged.
- The renderer is not changed for this feature; reveal is entirely a planning
  change (which text each raster holds and when).
- Per-word motion multiplies rasters; the fallback order under the input
  limit is: drop per-word motion first, then reveal, then the existing static
  page fallback.
- The control is visible in the Captions library editor, Highlight section.

## Model

`CaptionStyle` gains:

- `reveal: String?` (key `reveal`): `"none"` | `"word"`.
  `resolvedReveal` returns `"word"` only for that value, else `"none"`.
- `revealMotion: Bool?` (key `reveal_motion`): each revealed word uses the
  page entrance. `resolvedRevealMotion` defaults to `false`; it has no effect
  while `resolvedAnimation == "none"` or reveal is off.

## Planning

In `CaptionOverlayPlan.plan`, when `style.resolvedReveal == "word"`:

- States come from `CaptionWordStates.states` even when Highlight is "none".
- Walk the states keeping `visible: Int` (words shown so far, starts at 0).
  A state with `activeIndex = i` sets `visible = i + 1`. A silence state
  before the first word (`visible == 0`) produces no overlay. Any other
  silence state keeps `visible`.
- The raster for a state holds the page's first `visible` tokens joined by
  single spaces (tokens split on whitespace, as the renderer does);
  `activeIndex` stays `i` (nil in silence); `emphasis` keeps only indices
  `< visible`; the emoji is appended only when `visible` equals the page's
  token count. Highlight "none" leaves `activeIndex` nil so no word lights.
- Motion: with `resolvedRevealMotion` on and an entrance set, every state
  with a new `activeIndex` gets the entrance frames (the same frame schedule
  the first state gets today, clipped to that state's duration). With it off,
  only the first overlay of the page is animated, as today.
- Raster identity: `Raster` already hashes on text, so the cache keys differ
  per visible count; no change to `CaptionPNGCache`.
- Limit: if the overlays exceed `limit`, re-plan with `revealMotion` off; if
  still over, re-plan with reveal off (today's behaviour); then the static
  fallback. `Plan` gains `usedRevealFallback: Bool` for the status message.

The `CaptionRenderer.rowCount` / paging fit check is unchanged: a page that
fits in two rows complete also fits at every prefix.

## Editor

Highlight section of `CaptionStyleEditor`, under "Spoken word":

- Picker "Words appear": "All at once" (`none`) / "As spoken" (`word`).
  Help: "Show each word of a page as it is spoken. Makes no difference with
  one word per page."
- When As spoken: Toggle "Animate each word" bound to `revealMotion`, with
  `.formDependent()`. Help: "Each new word uses the Motion entrance; off
  animates only the page." Disabled with a caption "Choose a Motion entrance
  first." when `resolvedAnimation == "none"`.

## Tests (`CaptionOverlayPlanTests`)

- Reveal with Highlight off: a three-word page with word clocks yields
  rasters "a", "a b", "a b c" with the right windows and nil activeIndex.
- Leading silence produces no overlay; a mid-page gap repeats the current
  prefix; the emoji appears only on the full-page raster.
- Emphasis indices beyond the visible prefix are dropped.
- With pop entrance and revealMotion on, each word state starts with the
  entrance frames; with it off only the page's first state does.
- Fallback order: a plan over the limit drops motion, then reveal, and sets
  `usedRevealFallback`.
- `CaptionStyleTests`: legacy JSON resolves reveal "none"; round trip of
  `reveal` and `reveal_motion`.

## Verification

- Debug `build-for-testing` passes.
- Live: Captions library, Karaoke preset with Words appear: As spoken; Play
  Preview shows the page filling in and re-centring. Toggle Animate each word
  with Pop and see each word pop. Saved JSON holds `reveal` / `reveal_motion`.
