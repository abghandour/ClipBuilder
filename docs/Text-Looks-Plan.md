# Text Looks: one studio for captions, name tags and overlays

Date: October 29, 2026. Status: draft, approved in scope by the user (full
studio, same inspector shape on every surface). Nothing implemented.

Mockup: `Text Looks proposal.png` (rendered from the session scratchpad
`text-ui-proposal/proposal.html`). Critique that led here:
`.impeccable/critique/2026-10-29T12-23-16Z__clipbuilder-views-textdecorcontrols-swift.md`
(25/40; blind editing, looks as names, one flat 17-row stack tripled).

## What changes for the user

- One **Text Looks** surface with four tabs: Captions, Name tags, Overlays,
  Named styles. The sidebar rows Captions, Name Tags and Overlays stay (they
  are wayfinding) and open the studio on the matching tab.
- A **live stage** in the middle: the export renderer draws the sample on a
  black, colour or source-frame backdrop (the Overlays stage backdrop,
  promoted). Transport with the existing speed menu. The edited element has a
  selection box that can be dragged where the surface allows it.
- One **inspector** on the right, 320 pt, the same shape on every surface:
  state segment, Look row, Font, Colour, Effects, Spacing, footer. The Builder
  inspector hosts the same inspector for a text overlay.
- **Looks as thumbnails.** Named styles and built-in presets render as "Aa"
  cards in the inspector and in the style list. Copy, Paste and Save shrink to
  three icon buttons in the Look header.
- **Collapsible effects.** Stroke, Shadow, Box (today "Background") and Border
  are sections with a toggle in the header and a one-line summary when closed.
- **Override dots** replace the reset arrow on every row. A dot before a row
  marks a value this state sets; clicking it resets that row. The footer
  counts overrides and offers one "Reset state to <parent>".
- Shadow gets a **2-D offset pad** beside the X and Y fields; blur appears for
  Soft only. Every slider gains a numeric field.

Nothing in the stored models changes. `TextDecor`, `CaptionStyle`, `TagStyle`,
`TextOverlayItem`, `NamedTextStyle`, `TextShadowPresets` and
`TextStyleClipboard` are reused as they are. The settings keys that remember
the stage backdrop (`overlays.stage.*`) are reused across tabs.

## State lists per surface

| Surface | States (segment) | Parent of a state | Stage sample |
| --- | --- | --- | --- |
| Captions | Text · Highlight · Emphasis · Page | Highlight and Emphasis inherit Text; Page is the box (boxOnly) | `CaptionPreviewImage.frames` loop, click a word to pick its state |
| Name tags | Box · Name · Description | Name and Description inherit the shared style; Box is boxOnly | `TagPreviewImage` with image handles as today |
| Overlays (template item) | Text | shared style | `OverlayPreviewCanvas` with the template's other items dimmed |
| Builder text overlay | Text | shared style | the Builder preview itself (no stage in the inspector; the raster preview stays pinned above the controls) |
| Named styles | Look | none | a one-line sample through `TextOverlayPreviewImage` |

Captions-only rows (Words per page, Position, Words appear, Page entrance,
Emoji, Speaker colours, Highlight mode, Emphasis mode) move into the state
they belong to: page-level rows under Page, the Highlight mode picker at the
top of Highlight, the Emphasis mode picker at the top of Emphasis.

## Phases

### Phase 1: the inspector (view layer only)

New files under `ClipBuilder/Views/TextLooks/`:

- `TextLookInspector.swift`: the 320 pt panel. Takes a `TextLookSurface`
  (state list, bindings per state, stage sample kind) and renders the
  segment, Look row, Font, Colour, Effects, Spacing, footer. Replaces every
  `TextDecorControls(...)` call site.
- `TextLookInspectorSections.swift`: `FontSection`, `ColourSection`,
  `EffectSection` (generic collapsible with toggle + summary),
  `SpacingSection`. Each row uses `OverrideDot` instead of the reset button.
- `LookCard.swift`: the "Aa" thumbnail card. Renders through
  `TextOverlayPreviewImage.render` at a small canvas and caches by decor
  hash in a `nonisolated` actor (`LookThumbnailCache`) so a profile with
  twenty named styles does not re-render on every keystroke.
- `ShadowOffsetPad.swift`: 44 pt pad bound to `shadowX` / `shadowY`.
- `TextDecorControls.swift` is deleted once every call site moves.

`TextDecorEditing` (sparse override helpers) and `WizardFieldHelp.textDecor`
stay; new row keys (`shadowOffset`, `look`) get help entries and the
`WizardFieldHelpTests.textDecorationRowsHaveHelp` list is updated.

Tests: `TextLookSummaryTests` (closed-section summaries: "Off",
"Retro 3D · 1 override", "#FFD60A · radius 8 · per word"),
`LookThumbnailCacheTests` (same decor renders once), `ShadowOffsetPadTests`
(pad position round-trips to X/Y within the -3…3 range).

### Phase 2: the studio host

- `TextLooksView.swift`: three columns, `HSplitView` with
  `rememberedPaneWidth("pane.textLooks.list", min: 200, initial: 232, max: 300)`
  for the list and a fixed 320 pt inspector. Tab segment in the header. The
  `ContentView` cases `.captions`, `.tags`, `.overlays` route here with the
  tab preset; `SettingsView`'s Named Text Styles sheet becomes the fourth tab
  and the sheet is removed.
- `TextLooksStage.swift`: the stage. Backdrop controls move from
  `OverlayTemplateEditor.backdropControls` into the transport row (segment
  Black / Colour / Source, colour well, source picker, scrub). The 9:16 frame
  uses `OverlayPreviewCanvas` for overlays, the caption frame loop for
  captions, `TagStylePreview` for name tags.
- `TextLooksList.swift`: the left column. One `LookCard` thumbnail per style,
  the base look as the subtitle, a run-count badge from the wizard runs that
  reference the style (`Database+Runs` query; cheap count, cached per
  profile). "Presets" group lists `CaptionPresets.styles` and the tag presets;
  dragging or "Add" copies one into the profile as today.
- `CaptionStylesView`, `TagStylesView`, `NamedTextStylesView` and the
  per-item form in `OverlayTemplatesView` are deleted. `OverlayTemplatesView`
  keeps the template list and item list; its selected-item form becomes the
  inspector.

Tests: `TextLooksRoutingTests` (sidebar case to tab), and the existing
`CaptionStyleTests`, `TagStyleTests`, `TextStyleClipboardTests` keep passing
unchanged, which is the proof that the model did not move.

### Phase 3: Builder and Wizard hosts

- `BuilderInspector.TextInspector` hosts `TextLookInspector` with the single
  Text state; the raster preview stays pinned above a scrolling controls area
  (`VStack { preview; ScrollView { inspector } }`).
- `MiniSettingsCard` and `WizardView+Look` keep their style pickers but the
  picker menu items gain the `LookCard` thumbnail (`Picker` with a `Label`
  whose icon is the cached thumbnail).

### Phase 4: polish and removal

- Keyboard: ⌥⌘C / ⌥⌘V copy and paste the look in the studio and the Builder
  inspector (menu items under Format so they are discoverable).
- "Unavailable style" in the shared-style picker gains a "Replace with…"
  action.
- Save as Named Text Style shows an inline "Saved as 'Caption style 2'" with
  a Rename field for five seconds.
- Screenshots for the Training Guide (`scripts/capture_help_screenshots.sh`).

## Rules that apply

- Every control stays a native SwiftUI control: `Picker`, `Toggle`, `Slider`,
  `ColorPicker`, `DisclosureGroup` for the effect sections, `ControlGroup`
  for the bars. No custom chrome beyond `LookCard` and `ShadowOffsetPad`.
- Toolbar and row text is `lineLimit(1)` plus `fixedSize`, or `ViewThatFits`.
- Thumbnail rendering and caption frame rendering run off the main actor
  (`Task.detached`, as `TextOverlayRasterPreview` does now).
- The stage never holds a job; it only previews.
- Codex implements Phase 1 and 2 from this plan once the user says go; Claude
  builds, drives it live by pid, and reviews.

## Open questions

- Should the run-count badge count Wizard runs only, or Builder timelines too?
  Plan assumes runs only (one query, already indexed).
- Name tags have no "click a word" affordance. Plan assumes the stage shows
  the two lines with a hover outline and clicking a line picks its state.
