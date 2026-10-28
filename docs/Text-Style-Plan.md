# Text style: one decoration model for captions, name tags and overlays

Date: October 28, 2026. Status: draft, not reviewed. Nothing implemented.

## What the user asked for

"Everywhere that we support text in a video we must support the following
customizations: color, stroke, background, shadow, spacing, bold, italic,
casing, border, border thickness, border color, background on/off, background
color." Plus the ideas gathered in the same conversation (listed under
"Scope" below), all included.

## Where we stand

Three text surfaces, three models, three renderers, three editors. Each grew
its own subset of the same decorations.

| Surface | Model | Renderer | Editor |
| --- | --- | --- | --- |
| Captions (whole caption plus Text / Highlight / Emphasis word states) | `CaptionStyle` (`Data/BrandProfile.swift:332`) and `CaptionWordDecor` (`Data/CaptionWordDecor.swift`) | `Services/CaptionRenderer.swift` (`render(text:activeIndex:emphasis:)`, decorations around line 340) | `Views/CaptionStyleEditor.swift`, `Views/CaptionWordDecorControls.swift` |
| Name tags (name line, description line, box) | `TagLineStyle` and `TagStyle` (`Data/TagStyle.swift`) | `Services/TextOverlayRenderer+TagStyle.swift` (`drawStyledNameTag`) | `Views/TagStyleEditor.swift`, `Views/NameTagControls.swift` |
| Headlines, hero titles, strike stats, free text overlays | `TextOverlayItem` (`Data/TimelineModels.swift:1224`) | `Services/TextOverlayRenderer.swift` (`render(_:to:visibleWords:)`, `drawFittedBox`) | `Views/TextOverlayForm.swift`, `Views/OverlayWizardSheet.swift` |

Shared pieces that already exist and should stay: `TextStyleBar` (bold /
italic / underline / strikethrough segment bar), `FontFamilyPicker`,
`TextOverlayRenderer.parseColor` / `cgColor`, the preset lists
(`Services/CaptionPresets.swift`, tag presets), `NamedCaptionStyle` and
`NamedTagStyle`, and `BrandProfile.personCaptionStyles` (per-speaker caption
style by person key).

What each surface supports today:

| Decoration | Captions | Name tags | Overlays |
| --- | --- | --- | --- |
| Fill color | yes | yes | yes |
| Stroke width | yes | no | yes (em units) |
| Stroke color | no, fixed dark grey | no | yes |
| Shadow | on/off, fixed offset and blur | no | opacity only |
| Letter spacing | yes | no | no |
| Line height | no | no | no |
| Bold / italic | yes | yes | yes |
| Underline / strikethrough | yes | yes, with color and thickness | yes |
| Casing | uppercase only | uppercase only | no |
| Background on/off, color | yes | yes (line and box) | box opacity and color |
| Background opacity | fixed 0.25 or 1 | yes | yes |
| Background corner radius | yes | yes | no |
| Background padding | fixed (font size / 8) | fixed | fixed |
| Border (outline around the box) | no | no | no |
| Text opacity | no | no | whole element only |
| Alignment inside the box | whole caption | tag alignment | overlay alignment |
| Size | scale | scale per line | pixel size |
| Max width | words per page | fitted | words per line, locked width |
| Gradient fill | no | no | no |

Renderer quirks that the plan must keep or deliberately retire:

- Captions: stroke is drawn only when the whole-caption background is off
  (`CaptionRenderer.swift:376`). The highlight "box" state reuses the word
  background with its own padding and radius, and picks black or white text
  by luminance when no background color is set.
- Captions: `usesLegacyDecorations` keeps old profiles on the whole-caption
  fields when no per-state decor was ever written. Any new field must keep
  that split: state decor inherits from the Text state, which inherits from
  the legacy whole-caption fields.
- Overlays: stroke width is a fraction of font size (`strokeWidthEm`), the
  shadow is `shadowOpacity` with a fixed offset, and `boxOpacity` doubles as
  the background on/off switch (0 = off).
- Name tags: the box is one background behind both lines; each line can
  also have its own background (`TagLineStyle.bgOn`). Underline has its own
  color and thickness; captions and overlays use the text color and the
  font's underline thickness.

## Scope

Every surface gets the same decoration set. The user's list first, then the
additions from the conversation.

Required by the user:

1. Fill color.
2. Stroke: on/off, width, color.
3. Background: on/off, color.
4. Shadow.
5. Letter spacing.
6. Bold, italic.
7. Casing.
8. Border around the background box: on/off, thickness, color.

Added ideas, all in scope:

9. Shadow as a real control: color, x/y offset, blur, opacity, not just
   on/off.
10. Background padding, horizontal and vertical, in em so it scales with the
    font.
11. Line height for multi-line captions and headlines.
12. Casing options: as written, upper, lower, title.
13. Font size and a max width for every surface; a width cap controls
    wrapping better than words per line.
14. Gradient or two-tone fill: two colors and an angle.
15. Per-line background versus one block behind all lines.
16. Alignment inside the box: left, center, right, independent of the
    position on screen.
17. Text opacity separate from box opacity.
18. Shared named styles that apply to captions, tags and overlays, so a
    brand sets a look once.

Out of scope: animation and reveal (captions keep theirs), emoji, speaker
colors, highlight and emphasis selection rules, positioning and dragging,
overlay transitions. They are untouched by this plan.

## The model

One struct, embedded by every surface, every field Optional so existing
profiles, named styles, overlay templates and timelines decode unchanged
(the project rule: a new stored property is Optional or decoding breaks).

```swift
/// Every decoration a run of text in a video can carry. Nil inherits: a word
/// state from the caption's Text state, a tag line from the tag, an overlay
/// from its design's default. `resolved*` applies the defaults.
nonisolated struct TextDecor: Codable, Hashable, Sendable {
    // Fill
    var color: String?              // hex, "#ffffff"
    var fillEndColor: String?       // nil = flat; set = gradient to this color
    var fillAngle: Double?          // degrees, 0 = left to right, 90 = top to bottom
    var textOpacity: Double?        // 0...1, text and stroke only

    // Shape
    var weight: String?             // regular | bold | black
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var casing: String?             // asWritten | upper | lower | title
    var size: Double?               // em multiplier of the surface's base size
    var letterSpacing: Double?      // -2...6, in the caption renderer's units
    var lineHeight: Double?         // multiplier, 0.8...2, default 1.0

    // Stroke
    var strokeOn: Bool?
    var strokeWidth: Double?        // 0...6, same units captions use today
    var strokeColor: String?        // default "#000000"
    var strokeOpacity: Double?      // default 0.86 (today's caption value)

    // Shadow
    var shadowOn: Bool?
    var shadowColor: String?        // default "#000000"
    var shadowOpacity: Double?      // default 0.75
    var shadowX: Double?            // em, default 0
    var shadowY: Double?            // em, default -0.08 (today's -2 px at 1080)
    var shadowBlur: Double?         // em, default 0.15

    // Background
    var bgOn: Bool?
    var bgColor: String?
    var bgOpacity: Double?          // default 1 (captions today use 0.25 for a tinted word box)
    var bgRadius: Double?           // 0...40 at 1080 wide, default 6
    var bgPaddingX: Double?         // em, default 0.125 (font size / 8 today)
    var bgPaddingY: Double?         // em, default 0.125
    var bgPerLine: Bool?            // true = one rounded box per line; false = one block

    // Border around the background box
    var borderOn: Bool?
    var borderWidth: Double?        // 0...6 at 1080 wide, default 2
    var borderColor: String?        // default: the fill color

    // Layout
    var alignment: String?          // leading | center | trailing
    var maxWidthFrac: Double?       // 0.2...1 of the canvas width; nil = surface default
}
```

Rules:

- `TextDecor.merged(over base: TextDecor) -> TextDecor` fills nil fields
  from `base`. Inheritance chains are explicit per surface (below).
- `TextDecor.defaults` holds the resolved fallbacks in one place; every
  renderer reads `resolved(...)`, never a raw Optional.
- Colors stay hex strings as today. `parseColor` moves from
  `TextOverlayRenderer` into a `TextColor` helper the three renderers share.
- Units: em for anything that must follow font size (padding, shadow
  offset); "px at 1080 wide" for the sliders that already exist in those
  units (stroke width, radius, border) so current values keep their meaning.
- Border draws outside the background rect, with the same corner radius
  grown by half the border width. Border without background is allowed and
  outlines the text's bounding box; that is the "boxed label" look.
- Casing is applied before measuring, after markup parsing (overlay `*stars*`
  survive). Title case uses `capitalized` per word with a short stop-word
  list left lower (a, an, and, of, the, to) except at the start.
- Gradient fill: clip to the glyph path and fill a linear gradient; CoreText
  cannot fill text with a gradient directly, so each run becomes a path via
  `CTFontCreatePathForGlyph`. Stroke and shadow still apply to the path.

How each surface embeds it:

| Surface | Fields that become `TextDecor` | Inheritance chain |
| --- | --- | --- |
| `CaptionStyle` | the legacy whole-caption fields (`color`, `bgOn`, `bgColor`, `uppercase`, `weight`, `strokeWidth`, `shadow`, `letterSpacing`, `bgRadius`) and `CaptionWordDecor` for `text`, `highlightDecor`, `emphasisDecor` | state decor ← Text decor ← legacy fields ← `TextDecor.defaults` |
| `TagLineStyle` | `color`, `bold`, `italic`, `uppercase`, `underline`, `underlineColor`, `underlineThickness`, `strikethrough`, `bgOn`, `bgColor`, `bgOpacity`, `cornerRadius` | line decor ← tag decor (`TagStyle.decor`, new) ← defaults |
| `TextOverlayItem` | `fontcolor`, `bold`, `italic`, `underline`, `strikethrough`, `bgcolor`, `boxOpacity`, `strokeColor`, `strokeWidthEm`, `shadowOpacity`, `opacity` | item decor ← design default (hero, tag, plain) ← defaults |

The legacy fields stay stored and decoded; a one-way adapter
`legacyDecor` reads them into a `TextDecor` so old data renders as before.
New edits write the `decor` field only. Encoders keep writing the legacy
fields too for two releases so a downgrade still shows something, then the
legacy writes are dropped. `BrandSync` descriptors (`Data/Database+BrandSync.swift`)
gain the new columns, and a Supabase migration must ship with them, or every
push of that table fails (see the team-sync column lesson).

Named styles: `NamedTextStyle` (id, name, decor) is a fourth store on the
profile, next to `NamedCaptionStyle` and `NamedTagStyle`. A caption style, a
tag style, or an overlay design can reference one by id (`sharedStyleID`);
when set, its decor sits at the bottom of that surface's chain, just above
`defaults`. Editing the shared style changes every surface that uses it.
Per-speaker caption styles (`personCaptionStyles`) are untouched: they still
pick a `NamedCaptionStyle`, which may itself reference a shared style.

## The editor

One `TextDecorControls` view, used by all three editors, with the rows in a
fixed order so the three screens read the same:

1. Font (existing `FontFamilyPicker`), Size, Weight, Style bar (bold, italic,
   underline, strikethrough; `TextStyleBar`), Casing menu.
2. Fill: color, gradient toggle with end color and angle, text opacity.
3. Stroke: toggle; width, color, opacity as dependent rows.
4. Shadow: toggle; color, opacity, X, Y, blur as dependent rows.
5. Background: toggle; color, opacity, radius, padding X/Y, per line as
   dependent rows.
6. Border: toggle; width, color as dependent rows.
7. Spacing: letter spacing, line height.
8. Layout: alignment, max width.

Dependent rows follow the existing indent rule: toggle-on rows are indented
so their labels start at the parent control (`MiniDependents`,
`formCaptionIndent`). Every control's text is `lineLimit(1)` plus
`fixedSize`. Captions keep their three state tabs (Text, Highlight,
Emphasis), each hosting the same `TextDecorControls` with "Same as text" as
the nil label. Tags host it twice (name line, description line) plus the
box's own background/border rows. Overlays host it once.

Every row is also a visible control; nothing is context-menu only.

Preview: the three preview images (`CaptionPreviewImage`,
`TagPreviewImage`, the overlay form's preview) already re-render on style
change; they pick up the new fields through the renderers. The Look step's
preview in the wizard does the same.

## The renderer

A `TextDecorPainter` (nonisolated struct under Services) draws one run of
text with a resolved decor into a `CGContext`: measure, apply casing, build
the attributed string (font, kern, stroke attributes), draw background and
border, draw shadow, draw fill (flat or gradient), draw underline and
strikethrough with the same stroke and fill. The three renderers call it
per word (captions), per line (tags), or per line (overlays) and keep their
own layout: paging, highlight timing, tag images, hero bars, strike stats.

Drawing order per run: background, border, shadow, stroke, fill, rules.
Stroke is no longer suppressed when a background is on; the caption rule
that hid it existed because the fixed dark stroke looked wrong on a dark
box. With a stroke color control the user decides.

Pixel tests compare dominance and ranges, not exact values, because the
output is color-managed (pure red samples near 255, 38, 0). Existing tests
in `CaptionRendererTests`, `CaptionPreviewImageTests` and the overlay tests
stay green through Phase 2 by construction: the legacy adapter must resolve
to the same drawing parameters as today.

## Phases

Phase 0: model and adapter. Add `TextDecor`, `merged`, `defaults`,
`legacyDecor` adapters on the three models, `NamedTextStyle` storage on the
profile, BrandSync descriptors and the Supabase migration. Tests: decoding
of profiles and timelines from 1.128 fixtures, merge precedence per surface,
round trip of every field. No visible change.

Phase 1: painter. `TextDecorPainter` with flat fill, stroke, shadow,
background, border, rules, casing, letter spacing, line height. The caption
renderer switches to it first (most tests). Tests: pixel checks for each
decoration against a black and a white background; legacy adapter renders
the "Boxed", "Karaoke" and "Hormozi" presets within SSIM 0.99 of 1.128's
output (fixtures captured before the switch).

Phase 2: tags and overlays on the painter. Name tag box border and padding,
overlay box radius and border, per-line background on both. Tests: tag and
overlay pixel checks; `OverlayTemplateFiles` round trip.

Phase 3: editor. `TextDecorControls`, wired into the caption state tabs,
the tag editor and the overlay form; shared style picker row on each; the
Named Text Styles page under Settings › Profile. Tests: view tests for
binding precedence (nil shows the inherited value, edit writes only the
state's field), and `WizardFieldHelp` captions for every new row.

Phase 4: gradient fill, max width and alignment on captions, text opacity.
These need glyph paths and a caption layout change, so they come last.
Tests: gradient pixel check (two colors present, ordered along the angle),
caption wrapping at the width cap.

Each phase builds with `build-for-testing`; the suite runs in the release
gate only. Phases 0 to 2 are spec-complete enough for Codex to implement;
Phase 3 needs the row copy written first (`WizardFieldHelp`), Phase 4 needs
a short design pass on where captions wrap.

## Risks

- Profile and template decoding: the only safe shape is Optional fields and
  a one-way legacy adapter. No field is renamed or removed in this plan.
- Team sync: new columns without the server migration break every push of
  the brand table. The migration ships in Phase 0 with the descriptors.
- Caption PNG cache (`CaptionPNGCache`) keys on the style; the key must
  include the resolved decor, or edits show stale frames.
- Performance: gradient fill through glyph paths is slower than CoreText
  drawing. Captions render hundreds of PNGs per reel; keep the flat path for
  flat fills and measure the gradient path before enabling it on captions.
- Stroke on boxed captions changes the look of existing boxed presets only
  if the preset sets a stroke; the presets ship with stroke off when a
  background is on, so nothing changes by default.

## Open questions for the user

1. Should title case be on by default for name tags, where names are
   usually typed in mixed case anyway?
2. Should the shared named style also carry the font, or only decorations?
   The plan assumes decorations plus font family, since a brand look is
   mostly the font.
3. Do strike-stat overlays (`TextOverlayRenderer+StrikeStats`) take the
   full decor, or only fill, stroke and shadow? The plan assumes the full
   set, with the stat layout unchanged.
