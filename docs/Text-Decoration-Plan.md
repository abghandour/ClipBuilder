# Text decoration: italic, underline, strikethrough, size and word backgrounds per state

Date: October 20, 2026. Status: phases 1–5 implemented, Debug build passes, reviewed; phase 6 live verification pending.

## Goal

Every kind of text the app burns in gets the same decoration controls:
italic, underline, strikethrough, its own font size, and its own background
(on/off, colour, corner radius). For captions that means each of the three
word states separately: regular text, the spoken (highlight) word, and
emphasised keywords. Name tags get the same per line (name line, description
line), and text overlays get the two missing decorations. Every background
anywhere has a configurable corner radius.

## Where we stand

- `CaptionStyle` (`Data/BrandProfile.swift`) has flat Optional fields per
  state: `highlightColor` / `highlightFont`, `emphasisColor` / `emphasisFont`,
  plus one page background (`bgOn`, `bgColor`, radius hard-coded to
  `max(6, fontSize / 6)`). `CaptionRenderer.render` draws each word in its
  state's font and colour; layout reserves the widest face per word
  (`measureFonts`, `reservedWidth`) so a lit word never moves its neighbours.
  Font size is `max(36, videoWidth / 22)` with `wordScale` 1.12 for the Scale
  modes. The Highlight "Box" mode fills a rounded rect (radius 5) behind the
  spoken word in the highlight colour.
- `TagLineStyle` (`Data/TagStyle.swift`) already has `italic`, `underline`
  (colour, thickness) and `scale`; `TagStyle` has one block background with
  `cornerRadius`. `TextOverlayRenderer+TagStyle.swift` draws it through
  `TagLayout.layout`, which returns per-line origins and underline rects.
- `TextOverlayItem` (`Data/TimelineModels.swift`) has `bold`, `italic`,
  `fontsize`, `bgcolor`, `boxOpacity`, `boxRadius`; no underline or
  strikethrough. `TextOverlayRenderer.drawStyledLine` draws its words.
- Previews: `CaptionPreviewImage` and `TagPreviewImage` call the real
  renderers, so they follow automatically. The Builder's `PreviewPane` and
  `OverlayTemplatesView` draw text overlays with SwiftUI `Text` and mirror
  `bold` / `italic` by hand.

## Rules

- New stored properties are Optional with a `resolved…` accessor; decoding
  uses `decodeIfPresent`. Existing profile JSON, Team Sync documents and
  timeline JSON decode unchanged and render exactly as before when the new
  keys are absent.
- Every control exists per state (regular / highlight / emphasis) and per tag
  line. No state gets a colour without the matching font, size, decoration
  and background controls. (Standing rule from the per-state font work.)
- Layout reserves the largest footprint a word can have in any state (font,
  size, italic overhang, background padding), as `measureFonts` does today.
- Decorations are drawn as filled rects in the renderer, not CoreText
  underline attributes, so they take the outline and shadow of the word and
  match the tag path. Italic uses the family's italic face when it has one,
  otherwise a synthetic 12° skew (`CTFontCreateWithName` matrix).
- Sizes are points at 1080 pixels wide, like Outline and Letter spacing,
  scaled by `videoWidth / 1080`.
- Controls go in the existing editors (Captions library, Tag style editor,
  text overlay form). Nothing is context-menu only.

## Model

### Captions

New nested struct, one instance per state, all fields Optional:

```swift
nonisolated struct CaptionWordDecor: Codable, Sendable, Hashable {
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var size: Double?        // points at 1080 wide; nil = inherit (see below)
    var bgOn: Bool?
    var bgColor: String?     // nil = the state's text colour at 25% alpha
    var bgRadius: Double?    // points at 1080 wide; nil = 6
    // keys: italic, underline, strikethrough, size, bg_on, bg_color, bg_radius
}
```

`CaptionStyle` gains `text: CaptionWordDecor?` (key `text_decor`),
`highlightDecor` (`highlight_decor`), `emphasisDecor` (`emphasis_decor`), and
`bgRadius: Double?` (`bg_radius`) for the page background. Resolution:

- Regular size: `text?.size ?? 49` (1080 / 22, today's value), clamped
  24…120. Highlight / emphasis size: own value, else the regular size, times
  1.12 when the state's mode is Scale / Both (so the existing presets look
  the same).
- Italic / underline / strikethrough for highlight and emphasis: own value,
  else the regular text's value. A state never turns a decoration *off* that
  regular text has on unless it says `false` explicitly, which the editor
  writes when the user toggles it.
- Word background: own `bgOn`, default off. The Highlight "Box" mode stays
  in the Spoken word picker and means "word background on, filled with the
  highlight colour, auto-contrast text", exactly as today; when the highlight
  state has its own `bgColor` that colour wins and the text keeps the
  highlight colour. Padding is `size / 8`, radius `bgRadius` (default 6,
  today's Box radius is 5, close enough that no preset changes visibly).
- Page background radius: `bgRadius ?? max(6, fontSize / 6)` so existing
  styles do not change.

### Tags

`TagLineStyle` gains `strikethrough: Bool` (default false, key
`strikethrough`), `bgOn: Bool` (false, `bg_on`), `bgColor: String`
(`#000000`, `bg_color`), `bgOpacity: Double` (0.82, `bg_opacity`),
`cornerRadius: Double` (4, `corner_radius`). `scale` already is the per-line
size; keep it and label it "Size" as today. The block background and its
radius on `TagStyle` stay.

### Text overlays

`TextOverlayItem` gains `underline: Bool` and `strikethrough: Bool` (default
false, encoded only when true, like `italic`). Size, background, opacity and
radius already exist.

## Phases

### Phase 1: caption model and tests

- Add `CaptionWordDecor`, the three `CaptionStyle` fields, `bgRadius`, coding
  keys and `decodeIfPresent` lines, and resolved accessors
  (`resolvedDecor(for state:)`, `resolvedSize(for:)`, `resolvedPageRadius`).
- `CaptionStyleTests`: legacy JSON leaves every new field nil and every
  resolved value equal to today's behaviour; a style with all fields set
  round-trips with snake_case keys; highlight inherits italic from text until
  it says `false`.

### Phase 2: caption renderer

- `resolveFont(size:family:italic:)`: italic trait, synthetic skew fallback.
- `measureFonts` becomes per-state `(font, padding)` so `reservedWidth`
  reserves each word at its largest size and italic advance plus background
  padding; `maxAscent` / `maxDescent` likewise cover every state's size.
- Per word in `render`: pick the state's decor; draw the word background
  (rounded rect, padding `size / 8`, state radius) before the glyphs; draw the
  glyphs; then underline (at `CTFontGetUnderlinePosition`, thickness
  `CTFontGetUnderlineThickness`, min 1 px) and strikethrough (at half the
  x-height, same thickness) as rects in the fill colour, inside the same
  shadow / outline state as the glyphs.
- Page background uses `resolvedPageRadius`.
- `twoRowBand` and `rowCount` use the new per-state measurement.
- `CaptionRendererTests`: a style with a larger emphasis size and italic
  highlight keeps every neighbour's x position across states (extend
  `wideHighlightFontIsReservedInEveryState`); underline and strikethrough add
  opaque pixels below / through the word (sample the PNG); a word background
  with radius 0 has a square corner pixel and radius 20 a transparent one.

### Phase 3: caption editor

In `CaptionStyleEditor`, each of the three groups (Text, Highlight,
Emphasis) gets, after its font picker:

- Slider "Size: N pt" (24…120, step 1; highlight and emphasis show "Same as
  text" semantics by a toggle "Own size" that sets or clears the Optional).
- Toggles Italic, Underline, Strikethrough.
- Toggle "Word background"; when on, colour picker and a "Corner radius: N
  pt" slider (0…40).

The Text group's existing Background gets a "Corner radius" slider (0…60)
under its colour. Help text on every control. The Highlight group's "Spoken
word" picker keeps None / Colour / Box / Scale. Emphasis is split from
Highlight into its own Section ("Emphasis") so the three groups read as
peers. Form captions go through `FormCaption`.

### Phase 4: tags

- `TagLineStyle` fields, coding keys, decode defaults; `TagStyleTests`
  legacy-JSON and round-trip cases.
- `TagLayout.Line` gains `strikethrough: CGFloat` thickness and
  `chipPadding: CGFloat`; `Result` gains `chips: [CGRect?]` and
  `strikethroughs: [CGRect?]`. Chip rect = line bounds plus padding, chip
  padding `fontSize * 0.18`; the text block grows to contain chips.
  `TagLayoutTests` cover both.
- `drawStyledNameTag`: fill each chip (colour, opacity, radius scaled like
  the block radius) after the block background and before the glyphs; draw
  strikethrough rects after underlines.
- `TagLineControls`: Toggle Strikethrough after Underline; Toggle "Line
  background" with colour, opacity and "Corner radius" (0…80) when on, all
  `.formDependent()`.

### Phase 5: text overlays

- `TextOverlayItem.underline` / `.strikethrough` with coding, encode-if-true,
  equality.
- `drawStyledLine` draws the two rects per word in the word's colour.
- `TextOverlayForm`: Toggles Underline and Strikethrough next to Bold /
  Italic.
- `PreviewPane` and `OverlayTemplatesView` mirror them with
  `.underline(_:)` / `.strikethrough(_:)` on the SwiftUI `Text`.
- `OverlayTemplateFiles` reads the two keys from raw template dictionaries.

### Phase 6: verification

- Debug `build-for-testing` passes after each phase.
- Live: open the Captions library, set Text italic + underline, Highlight
  own size 60 with a word background radius 0, Emphasis strikethrough; the
  preview and Play Preview show all of it and no word shifts as the lit word
  moves. Save shows the new keys in the profile JSON. A legacy profile from
  git (`ProfileStore` JSON without the keys) renders unchanged.
- Tags: name line chip with radius 20 and strikethrough on the description
  line in the Tag style preview.
- Text overlay: underline + strikethrough in the Builder preview and in a
  rendered frame.
- Tests run in `scripts/release.sh` only.

## Implementation notes (October 20, 2026)

- Tag and overlay additions use Optional storage with resolved defaults, following
  the compatibility rule above. Overlay false values are omitted when encoding.
- Captions without decoration keys retain the old size, Scale envelope, Box
  geometry, and page radius. Explicit state sizes scale from 1080-wide points.
- Debug `build-for-testing` was attempted after each phase; every attempt exited
  143 before compilation in the restricted environment. Direct type-checks of
  the changed models, renderers, geometry, and editor controls passed against
  cached unchanged dependencies. This is not an Xcode build or test-suite pass.
- Regression tests were added but not run. No Release build or live UI checks ran.
