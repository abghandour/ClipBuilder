# Caption templates: word-level highlight, animated styles, emphasis

Date: October 20, 2026. Status: phases 1–5 implemented; full build and live verification pending.

## Goal

Captions that look like the short-form apps people know (Captions / Mirage,
CapCut): the spoken word lights up as it is said, pages pop in, keywords and
numbers stand out, and a library of ready templates picks all of that in one
click. Everything renders from the edited transcript and its word clocks
(docs/Transcript-Editing-Plan.md), on any aspect ratio and length, in any
translated language.

## Where we stand

- `Services/CaptionRenderer.swift` draws one PNG per caption page (CoreText
  into a CGContext: font, colour, optional rounded background, outline when
  there is no background). `Services/CaptionPaging.swift` cuts a transcript
  segment into pages that fit two rows, using the word clocks for page times.
- Two render paths overlay those PNGs with ffmpeg `overlay=…:enable='gte(t,a)*lt(t,b)'`:
  the Builder (`MultitrackRenderer.segmentPlan`, cached per text in
  `CaptionPNGCache`) and the Wizard (`WizardEngine` around line 4025,
  `RenderEngine.ClipOverlay`, which already carries an unused `animation`
  field).
- `CaptionStyle` in `Data/BrandProfile.swift` has font, colour, background
  on/off and colour, position, alignment. Named styles live in
  `BrandProfile.captionStyles`, edited in `Views/CaptionStylesView.swift` /
  `CaptionStyleEditor.swift` with `CaptionStylePreview.swift`, and chosen in
  the Wizard's Look tab and the Builder.
- Tests: `CaptionPagingTests`, `CaptionRendererTests`; renders compare by
  timing, audio and SSIM, never bytes.

## Rules

- The renderer stays a `nonisolated struct` producing PNGs; both paths keep
  the enable-window composite. No Core Animation, no second compositor.
- Every new `CaptionStyle` property is Optional with a default accessor so
  existing profile JSON and Team Sync documents decode unchanged.
- Every setting has a visible control in the Captions library editor; the
  Wizard Look tab and the Builder only pick a named style.
- Word clocks come from `transcripts.words` (realigned after edits). A
  translation has no clocks: its pages get proportional word timing from
  `CaptionPaging`'s fallback, and the highlight still runs.
- Pure logic (page planning, word states, emphasis picking, frame schedules)
  lives in `nonisolated` enums under Services with tests. Rendering never runs
  on the main actor.

## Phase 1: the template model

Extend `CaptionStyle` (all Optional, `CodingKeys` snake_case like the rest):

| Property | Values | Default |
| --- | --- | --- |
| `wordsPerPage` | 1 … 8, nil = fit two rows (today) | nil |
| `highlight` | "none", "color", "box", "scale" | "none" |
| `highlightColor` | hex | "#ffd60a" |
| `emphasis` | "none", "color", "scale", "both" | "none" |
| `emphasisColor` | hex | highlightColor |
| `uppercase` | Bool | false |
| `weight` | "regular", "bold", "black" | "bold" |
| `strokeWidth` | 0 … 6 pt at 1080 wide | 1 (today's outline) |
| `shadow` | Bool | false |
| `letterSpacing` | -2 … 6 | 0 |
| `animation` | "none", "pop", "slide-up", "fade" | "none" |
| `emoji` | Bool | false |
| `speakerColors` | Bool | false |

`CaptionRenderer.render` honours uppercase, weight (CTFont with the bold
or black trait, or the asset font as is), stroke width, shadow and letter
spacing. `CaptionPaging.pages` takes `maxWords: Int?` and caps a page at
that many tokens before the fit check.

**Presets.** `Services/CaptionPresets.swift`, a `nonisolated enum` with six
`NamedCaptionStyle` values: Clean (outline, two rows), Boxed (background,
two rows), Karaoke (colour highlight, pop), Hormozi (one word per page,
black weight, uppercase, scale highlight, emphasis colour), Three-Word (three
per page, box highlight), Lower Third (leading alignment, box, no highlight).
The Captions library gets an "Add Preset" menu that inserts a copy the user
can edit. Presets are code, not profile data, so a profile can be reset.

**Editor and preview.** `CaptionStyleEditor` gains the controls, grouped
Text / Highlight / Motion. `CaptionStylePreview` plays a sample line of
five words through the word states and the animation frames on a timer, so
the library shows the motion without a render.

Tests: `CaptionStyleTests` (decoding old JSON gives defaults; round trip),
`CaptionPagingTests` additions for `maxWords`.

## Phase 2: word states

`Services/CaptionWordStates.swift`:

```swift
nonisolated enum CaptionWordStates {
    struct State: Equatable, Sendable {
        var page: CaptionPage
        var activeIndex: Int?     // nil: no word lit (gap before the first word)
        var start: Double
        var end: Double
    }
    /// One state per word of the page, timed by the word clocks that
    /// describe this page's tokens; a page without clocks gets equal shares.
    static func states(for page: CaptionPage, words: [TranscriptWord]?) -> [State]
}
```

`CaptionRenderer.render(text:activeIndex:emphasis:)` draws the lit word with
the highlight mode: colour swaps the fill; box draws a rounded rect behind
that word in the highlight colour; scale draws it 12% larger on the same
baseline (the box grows by the difference so nothing shifts). The PNG is
keyed by `(text, activeIndex, emphasisIndices)` in `CaptionPNGCache` and in
a matching cache for the Wizard path.

Both render paths replace the one overlay per page with one overlay per
state when `highlight != "none"`. Overlay counts grow by the words per page
(about three times for two-row pages); ffmpeg takes hundreds of PNG inputs
per segment without issue, but the plan caps a segment at 400 caption
inputs and falls back to page overlays beyond that, with a log line.

Tests: `CaptionWordStatesTests` (clocks respected, gaps, no clocks, one-word
pages), `CaptionRendererTests` additions (a lit word keeps the box width
within one pixel of the unlit page so the overlay does not jump).

## Phase 3: animation

`Services/CaptionAnimation.swift`: `frames(for style: String, duration:
Double) -> [Frame]` where a frame is `(scale: CGFloat, offsetY: CGFloat,
alpha: CGFloat, at: Double)`. Pop: 0.85 → 1.08 → 1.0 over 180 ms in five
frames; slide-up: 24 px rise over 160 ms in four frames; fade: alpha over
160 ms in four frames. The renderer draws each frame into its own PNG from
the same layout (scale and offset applied to the context transform, alpha to
the fill); the first state of each page gets the frames as overlays with
30–45 ms windows, then the steady PNG. The last frame equals the steady PNG
so the cut is invisible. Frames are cached like states.

Tests: `CaptionAnimationTests` (monotonic times, last frame is identity,
total length equals the requested duration, no frame beyond the page end).

## Phase 4: emphasis and emoji

`Services/CaptionEmphasis.swift`:

```swift
nonisolated enum CaptionEmphasis {
    /// Token indices worth emphasising on one page: numbers, money,
    /// percentages, proper nouns, and the one noun NLTagger scores highest;
    /// at most two per page, never two adjacent.
    static func indices(for page: CaptionPage, language: String) -> [Int]
    /// An emoji for the page when a word maps to the small built-in table
    /// (money, fire, win, time, strong, love, laugh, warning); nil otherwise.
    static func emoji(for page: CaptionPage, language: String) -> String?
}
```

On device, no model call, `NaturalLanguage` as `LocalTextMatcher` already
uses it. The emoji is appended to the page text and drawn by CoreText with
the colour emoji font fallback. An optional AI pass is a later phase: a new
`AITask` case `captionEmphasis` with a prompt that returns keyword indices
and an emoji per page in one call per clip, routed in `AICatalog`, with
provenance; the on-device pass is the fallback and the default.

Tests: `CaptionEmphasisTests` with English and Portuguese lines.

## Phase 5: speaker colours

When `speakerColors` is on and the clip's video has speaker turns, the
page's text colour comes from a palette indexed by the speaker key of the
line (`TranscriptSpeakers.label` already resolves it). The Captions editor
shows the palette (four colours) under Text. Pages whose lines span two
speakers use the first.

## Out of scope

- Punch-in zoom on emphasised words (framing work, separate plan).
- Sound effects on emphasis.
- Per-word manual styling in the Builder.
- A Captions / Mirage API round trip: their API returns rendered video only,
  ignores our transcript edits and translations, and accepts only 9:16 under
  five minutes.

## Verification

- `build-for-testing` in Debug after each phase; tests run in
  `scripts/release.sh`.
- Live: pick Karaoke in the Captions library and watch the preview; render a
  Wizard reel and a Builder timeline with it on a Portuguese podcast with an
  English translation; the lit word follows speech in the original language,
  and the translation highlights at even pace. Compare two renders of the
  same timeline by timing, audio and SSIM, not bytes.


## Implementation results

October 20, 2026.

- **Phase 1 completed:** all thirteen Optional settings, snake_case keys and
  default accessors; retained the existing legacy-field decoder. Added font
  weight, uppercase, outline, shadow and spacing rendering; word-count caps
  (including short-tail merges); six copyable presets and the visible Add
  Preset menu. CaptionStyleEditor groups controls under Text / Highlight /
  Motion, including position and the speaker palette. The five-word preview
  plays pre-rendered states and frames, supports pause and Reduce Motion, and
  cancels obsolete background work after edits.
- **Phase 2 completed:** CaptionWordStates preserves exact page-local word
  clocks, emits unlit silence windows and evenly times text without matching
  clocks. CaptionPage carries its precise word slice so repeated words cannot
  match the wrong occurrence. Colour, box and 12% scale rendering share fixed
  geometry. Builder and Wizard use CaptionOverlayPlan and CaptionPNGCache;
  keys include text, active word, emphasis indices, speaker colour and frame.
  Both retain ffmpeg's existing enable-window composite.
- **Phase 3 completed:** pop, slide-up and fade schedules, bounded to the first
  state; identity endpoint and cached steady raster; a fixed padded raster
  envelope prevents motion clipping or overlay jumps. Slide/fade use four
  40 ms transition windows plus the identity endpoint; pop uses four 45 ms
  windows plus its fifth, identity frame. Planning retains the original page
  clock before clipping to a render segment, so mid-page cuts neither replay
  entrances nor retime translations. Pop's overshoot is reserved inside the
  safe width; name-tag clearance includes the motion envelope.
- **Phase 4 completed:** on-device NaturalLanguage selection prioritizes
  numbers/money/percentages, named entities, then the highest-confidence noun;
  at most two nonadjacent token indices. English/Portuguese emoji vocabulary
  uses accent-insensitive matching. Emoji is appended after word-state timing
  and is included in page-fit measurement and CoreText rendering.
- **Phase 5 completed:** both render paths read the active video's speaker
  turns and original rows when enabled. The fixed four-colour palette follows
  stable person/feed/cluster identity across cuts and translations. Explicit
  line attribution wins; unknown attribution retains the base colour; a line
  crossing speakers uses its first overlapping turn. The editor displays the
  numbered palette and the preview demonstrates a speaker colour.

### Limits and deliberate choices

- The shared planner enforces 400 caption inputs per Builder segment/Wizard
  clip, counting entrance frames as inputs. Over-budget plans log a fallback
  to static pages. If one-word pages alone exceed 400, the fallback regroups
  consecutive pages within each caption stream without dropping text; the
  renderer fits the regrouped text to two rows. A regrouped page uses its
  first speaker colour. More independent caption streams than the input
  budget produce an actionable error rather than silently omitting captions.
- The optional AI emphasis pass is **not implemented**: the plan explicitly
  reserves its AITask/catalog/provenance work for a later phase. No other
  requested phase was skipped. Punch-ins, sound effects, manual per-word
  styling and external caption APIs remain out of scope.
- Existing transcript-editing changes are preserved. The original staged
  diff was compared byte-for-byte with the starting snapshot and is unchanged;
  CaptionPaging has additive working-tree changes on top of its staged edits.
  No commit, push, release build, protected-file edit or test execution.

### Verification results

- Added **22 Swift Testing tests** across CaptionStyleTests,
  CaptionWordStatesTests, CaptionAnimationTests, CaptionEmphasisTests,
  CaptionSpeakerColorsTests and CaptionOverlayPlanTests, plus additions to
  CaptionPagingTests and CaptionRendererTests. Coverage includes legacy JSON,
  round trips, word limits, silence/repeated words/translations, slow motion,
  clipping, non-restarting entrances, emoji clocks, input caps, cache keys,
  speaker attribution, stable raster geometry and animation safe width.
- Requested Debug `build-for-testing` attempted after each phase. Every
  attempt was terminated by the sandbox with **exit 143 before compilation**,
  accompanied by Xcode/CoreSimulator XPC/log permission errors. There is no
  successful app or test-target build result.
- Limited direct Swift typechecking passed for the current caption model,
  services/renderer and extracted Builder/Wizard caption integration blocks
  against existing Debug dependency modules. Regression-test bodies were also
  typechecked using temporary assertion-function replacements because Swift
  macro plugins cannot run in this sandbox. These checks are not an Xcode
  build and do not verify test discovery, macro expansion, linking or behavior.
- Source-only UI review found a paused Fade preview could remain blank after
  edits; fixed by retaining a sample time beyond the entrance and verified by
  the reviewer. No visual approval is claimed. `git diff --check` passed.
- **Still unverified:** full Debug build-for-testing, actual Swift Testing
  compilation/execution, live editor/preview accessibility and layout,
  Portuguese speech with English translation through both render paths,
  rendered timing/audio/SSIM comparisons and performance at the input limit.
  Run the prescribed Debug compile check outside this sandbox; tests stay
  deferred to the release workflow as instructed.

### Review fixes (Claude, October 20, 2026)

- Every still PNG input gets `-threads 1` in both ffmpeg graphs. ffmpeg
  otherwise starts a frame-thread pool per input (about 13 threads each on a
  12-core Mac), and 440 inputs hit the process thread limit; the cap also
  drops from 400 to 300 inputs for margin next to the video decoders and
  the encoder.
- The speaker palette no longer starts with the default highlight colour,
  so a lit or emphasised word always differs from the first speaker's text.
- Weight defaults to regular, so profiles from before templates render as
  they did; the presets set bold or black explicitly. Black asks for the
  heaviest face at normal width and keeps bold when the family only offers a
  condensed heavier face (Helvetica Neue, Futura).
- Speaker-colour reads and a caption that fails to rasterize degrade as the
  caption path always did (uncoloured, skipped) instead of failing the
  segment or clip.
- Verified live in the Captions library on a scratch profile: the Text,
  Highlight, Motion and Preview sections and the Add Preset menu with the six
  presets. Adding a preset and watching the animated preview were not
  completed (the shared desktop's window order changed mid-check, so
  driving stopped).

### Follow-ups (Claude, October 20, 2026)

- The Captions library shows the preview in a third split column to the
  right of the editor, pinned at the top, instead of a section at the bottom
  of the form.
- `highlight_font` and `emphasis_font` on `CaptionStyle` (nil: the text font)
  give the lit word and emphasised keywords their own family; the editor's
  Highlight and Emphasis groups each get a font picker whose empty pick reads
  "Same as text".
- Layout reserves, per word, the widest of the text, highlight and emphasis
  fonts (and the tallest ascent and descent), so a wide highlight font never
  moves or overlaps its neighbours.
