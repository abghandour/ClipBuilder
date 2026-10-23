# Preview drag positions: place captions, name tags and the overlay by hand

Date: October 23, 2026. Status: phases 1–3 implemented; Debug build passes, 143 tests across the touched suites pass, caption and name tag drags verified live in Express (scratch instance); overlay drag, the full wizard and a render with custom positions not yet checked live.

## Goal

In the AI Wizard Express and full AI Wizard preview, the user drags the
caption, a name tag or the fixed overlay to where they want it. The element
adopts a custom position, the matching position picker reads "Custom", and
the exact position is stored with the other settings (per-profile memory,
Express presets, Team Sync, run provenance) so the render puts it exactly
where the preview showed it.

## Design

### One encoding, the existing settings

A custom position is the element's centre as fractions of the canvas,
stored as a string `custom:<x>,<y>` (four decimals). It lives in the
position settings that already exist, so no schema changes anywhere the
string already travels:

| Element | Setting | Values before | Now also |
| --- | --- | --- | --- |
| Captions | `WizardOptions.captionPosition` / `MiniWizardSettings.captionPosition` | nil (Auto), bottom, middle, top | `custom:x,y` |
| Name tags | `WizardOptions.nameTagPosition` / `MiniWizardSettings.nameTagPosition` | nil (Auto), four corners | `custom:x,y` |
| Fixed overlay | new `WizardOptions.fixedOverlayPosition` / `MiniWizardSettings.overlayPosition` | – | nil (as designed) or `custom:x,y` |

`CustomPosition` (`Services/Wizard/CustomPosition.swift`) parses and formats
the string and clamps a box of a given size so it stays inside a bounds
rect. Per-person tag corners (the "Tag position" person field) still win
over the run setting, as they do for the corner choices.

### Render

- `CaptionRenderer.position(for:positionOverride:)` and
  `position(for:clipPosition:)`: a custom position centres the caption on
  the point, clamped to the frame; when the safe area applies (safe area
  only, or the Builder's clip path with a safe area) it is clamped into
  the safe area as well. `WizardOptions.captionPositionOverride` passes
  custom strings through (it used to drop anything but the three words).
- `NameTagPlanner.plan`: a custom run position centres each tag on the
  point inside its area's allowed rect; it is never moved for the caption
  band (the user put it there), but two tags on screen at once still
  stack away from each other along the nearer edge.
- `WizardFixedOverlay.block`: a custom position shifts the whole
  composition so its bounding box centre lands on the point, clamped so
  the box stays inside the frame. `WizardFixedOverlay.bounds(of:canvasAspect:)`
  gives the box (texts from their fractions, images assumed square at
  their width) and is also what the preview uses for the drag handle.

### Preview

- `WizardPreviewComposite.render` reports a `Layout` with the canvas-pixel
  rects of the caption, each name tag and the fixed overlay; the model
  keeps it with the image.
- `WizardPreviewColumn` draws a handle over each rect: invisible until
  hovered, a dashed outline and open-hand cursor while hovering, moves
  with the drag, and on release calls `onMove(element, CustomPosition)`.
  Express writes the string into `miniSettings`; the full wizard writes
  its caption choice, tag position and overlay position settings.
- `CaptionPositionPicker`, `NameTagControls` and the overlay rows show a
  "Custom" entry while the value is custom; choosing anything else resets.

## Phases

1. `CustomPosition` + render support: caption renderer, caption override,
   tag planner, fixed overlay repositioning and the new
   `fixedOverlayPosition` field through options, step-2 options, decoding,
   Express settings/memory/presets, wizard extras, run settings keys.
   Tests next to each.
2. Preview layout + drag handles + picker "Custom" entries + Express and
   full wizard wiring.
3. Verification: Debug build; live in Express: drag the caption up, the tag
   to the left, the overlay down; pickers read Custom; a render puts them
   there; choosing Auto resets.

## Implementation notes — October 23, 2026

- Handles are always faintly outlined (white, 45 %) and turn accent on hover
  or drag; synthetic hover alone did not reveal an invisible handle during
  verification, and a visible affordance is the project's rule anyway.
- Dragging the caption in Express stored `custom:0.5000,0.5603` in
  `mini.<profile>.captionPosition`; dragging the tag stored
  `custom:0.3238,0.3340` in `nameTagPosition`, and the preview re-rendered at
  both spots.
- The composite's `Layout` for the overlay uses `WizardFixedOverlay.bounds`,
  the same estimate the repositioning uses, so the handle and the move agree
  even when an image's real aspect differs from the square assumption.
