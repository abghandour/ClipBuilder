# Rough cut: an Overlays tab in the review sheet (Express)

Date: November 6, 2026. Status: implemented November 6, 2026 (Claude); see "Status" at the end.

## Why

The rough cut sheet (docs/Rough-Cut-Plan.md) shows framing and focus in
motion with every presentation layer stripped. Captions, name tags, the
overlay design and the watermark could only be checked by a full render.
The user asked for a second tab in the sheet, in the panel tab style, with
the same Overlays controls Express has on its Settings card, applied to the
sheet's own preview: drag captions, name tags and overlay items on the
picture, Play renders the cut with them, Apply hands both the framing and
the overlay settings back to the page.

## Design

- **The sheet's settings live in `RoughCutExtras`.** `extras.overlays`
  (`RoughCutOverlays`: a `MiniWizardSettings` copy plus the two page facts
  the rows need, `showsNameTags` and `showsCaptionLanguage`) joins `look`
  and `transition`. Nil keeps the rough cut plain, as the full wizard's is.
  Express starts its rough cut with its effective settings
  (`generateWizardBatch(roughCutOverlays:)`), so the tab opens on the page's
  current Overlays choices and the first Play renders them.
- **`WizardRoughCut.options`** still turns every layer off, then, with
  overlays, puts the overlay layers back from the settings through the
  same mapping Express's Generate uses: `MiniWizardSettings.
  applyOverlayOptions(to:)`, extracted from `step2Options`, merged through
  `WizardOptions.merge` as `previewOptions` does. Music, dub, bumpers,
  cards, speech polish, B-roll and the small canvas stay as before.
- **`WizardRoughCut.strip`** keeps the document's text and image
  overlays, overlay blocks, brand layers and per-clip captions when
  overlays are on; cards, cutaways, sound and dub still go.
- **The sheet** gets `PageTabs` (Picture | Overlays) when overlays are
  editable (Express namespace and `extras.overlays` set). Picture holds
  Effect, Transition and the framing rows as before. Overlays holds
  `MiniOverlayRows`, the rows extracted from `MiniSettingsCard` and bound
  to the sheet's copy. On the Overlays tab the still with the pending
  settings covers each picture even when the cut is current, and its drag
  handles are live (`onMove`, `onPlaceOverlay` as on the Express page);
  on Picture the still shows only while the cut is stale, as before.
  Any change marks the cut stale; Play renders through `rerunRoughCut`
  with the extras, which now carry the overlays.
- **Apply** sends the framing as before and the overlay settings as
  `AssistantCommand.expressOverlays`; `MiniWizardView` adopts them with
  `MiniWizardSettings.adoptingOverlays(from:)` (overlay fields only, the
  rest of the page's settings untouched) and the page remembers them.
- The full wizard's rough cut is unchanged (one tab, plain cuts).

## Files

- `Services/Wizard/MiniWizardSettings.swift`: `applyOverlayOptions(to:)`,
  `adoptingOverlays(from:)`.
- `Services/Wizard/WizardRoughCut.swift`: `RoughCutOverlays`,
  `RoughCutExtras.overlays`, `options`/`strip`/`leftOut(overlays:)`.
- `App/AppStore+WizardBatch.swift`, `App/AppStore+MiniWizard.swift`:
  `roughCutOverlays` plumbing.
- `App/AppStore+Assistant.swift`: `AssistantCommand.expressOverlays`.
- `Views/MiniOverlayRows.swift` (new, from `MiniSettingsCard`).
- `Views/RoughCutReviewSheet.swift`: tabs, still with handles, Apply.
- `Views/MiniWizardView.swift`: adopt overlays on Apply / Generate.
- Tests: `WizardRoughCutTests`, `MiniWizardSettingsTests`.

## Status

Implemented November 6, 2026; Codex review applied the same day (still lifts during playback, caption language row from the transcript language, dub caption language). Same day: a dragged name tag position now beats a person's own corner in `NameTagPlanner` (the drag was being ignored for people with their own corner), and a dragged tag is no longer clamped to the platform safe area unless Safe area only is on. Later the same day (user rule): Safe area only resizes the frame only for Auto and corner captions and name tags; a dragged caption or tag keeps its spot whatever the toggle (`CaptionRenderer.customOrigin` with `respectSafeArea: false`, `NameTagPlanner.keepsSafe`), and the preview shades the unsafe zones whenever the toggle is on (`PlatformChromeLayer.safeAreaOnly`, fed from `WizardPreviewColumn` by `options.resolvedSafeArea`), independent of the Simulate menu; the rough cut sheet shades the player picture itself (`ScrubbingPlayerView.pictureChrome`) so it stays during playback, and the zones are drawn in one Canvas after offset Rectangles ghosted over the player. Later still (user rule, after Top right showed bottom right because John had his own corner): the run-wide Name tag position is removed; each person's own position (People list, or a drag on their tag, saved to their Tag position field) places their tag, Auto otherwise. Later the same day (user rule): the Express and full wizard third column only plays the kept clips as recorded, aspect-filled to the output format, with a clip stepper, speed control and Play All (`WizardPlayerColumn`, `KeptClipsPlayer`); every settings preview, including placing the focus frame (Picture tab), lives in this sheet. See HANDOFF.md for what was driven live.
