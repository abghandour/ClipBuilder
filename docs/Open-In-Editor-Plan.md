# Open in Editor from the AI wizard

Date: November 1, 2026. Status: implemented (Claude), tests written but not run, not driven live. Requested by the user
on November 1, 2026.

## What the user asked for

On both AI wizard pages (Express and Full) an "Open in Editor" button next to
"Generate Video" loads the kept/selected scenes into a new Builder timeline
with every current setting applied (captions, overlays, music, picture
preset, center stage/focus, transitions, bumpers, B-roll, dub, safe area),
so that rendering that timeline from the Builder without changes gives the
same output as Generate Video.

## Why a new path is needed

`WizardEngine.assemble` builds the document and then burns several things
in outside it: caption style id and language (with translation), caption
safe-area and speaker-position options, the logo watermark and headline
layers, the per-clip content-box crop, the wizard music mix (fixed gain, 2 s
fade, no ducking), and the center-stage camera default. The Builder renders
from the document alone, so a saved wizard timeline re-renders differently.

## Design

1. **Split assemble.** In `Services/WizardEngine.swift`, factor the part of
   `assemble` from the caption/profile setup through the document build and
   its post-processing (name tags, per-clip captions, cards, bumpers, B-roll,
   overlay blocks, dub) into `prepareDocument(...) -> PreparedAssembly`
   (document, cut documents, brand layers, cards, caption context). The
   remainder becomes `renderPrepared`. `assemble` = prepare + render, with
   no behaviour change. Move the `renderPlan:` hook after `snapCutsToBeats`.
2. **Editor document.** `WizardEngine.editorDocument(selection:take:options:
   profile:)` runs `renderSelection`'s pre-assemble steps (pacing,
   transitions, music, overlay style, `snapCutsToBeats`) and `prepareDocument`
   and returns the document with no encoding.
3. **Document fields** (all Optional, `decodeIfPresent`, in
   `Data/TimelineModels.swift`), honored by `MultitrackRenderer.render
   (document:)` so the Builder matches the wizard:
   - `captionStyleID: String?`, `captionLanguage: String?`,
     `captionSafeAreaOnly: Bool?`, `speakerCaptionPositions: [String:
     String]?` (keyed by person key, or the existing type). The Builder
     renderer resolves `profile.withCaptionStyle(id)` and the language the
     same way assemble does, falling back to today's behaviour when nil.
   - Brand layers: the logo watermark and headline become `imageOverlays`
     (full duration) when the wizard would burn them; if `ImageOverlayItem`
     cannot express the exact placement, add an Optional `brandLayers:
     [BrandLayer]?` the renderer composites per clip the way assemble does.
   - `contentWindows` per clip: `TimelineClip.contentWindow: CGRect?`
     (normalized) passed to the extraction like assemble's `contentWindows`.
   - `framingCamera: String?` document-level default for center stage; the
     Builder render uses it before `WizardDefaults.fallbackFramingCamera`.
   - `musicMix: String?` = "wizard" makes the Builder's music stage use the
     wizard's `overlayMusic` behaviour (fixed gain, 2 s fade, no ducking)
     instead of `buildMusicTrack`.
   The document assemble produces sets all of these so the saved
   `timeline_json` of a generated video also re-renders faithfully.
4. **Shared batch mode.** `generateWizardBatch(..., mode: .render | .openIn
   Editor)` in `App/AppStore+WizardBatch.swift`: the gather, camera-focus
   pass, one-reel combine and tag-text steps run as today; in
   `.openInEditor` each reel's take goes through `editorDocument` and
   `createTimeline(named:document:isWizardPlan:)` (one timeline per reel,
   named after the reel/selection; the first opens in the Builder). Express
   records picks first (`generateMiniVideosRecordingPicks`). The work runs
   as an `AppJobs` job ("Open in Editor") with a status-bar row, and opens
   the Builder when done.
5. **Buttons.** Express: `Views/MiniGeneratePanel.swift` gets "Open in
   Editor" next to "Generate Video", enabled under the same conditions.
   Full: `Views/WizardView.swift` `generationBar` and the `generatePanel`
   in `WizardView+Look.swift` get it next to Generate, enabled only when
   `flow.settingsRenders` is true (the plans come from saved takes; AI
   planning modes have nothing to open). Text `lineLimit(1)` + `fixedSize`.
6. **Known non-identical parts** (told to the user): hardware encodes are
   never byte-identical; intro/outro cards must exist in the retained cards
   folder (prepare generates them exactly as assemble does); a dub that has
   not been reviewed yet is created with the same defaults assemble uses.
7. **Tests.** `ClipBuilderTests/Services/WizardEditorDocumentTests.swift`:
   `editorDocument` output equals the document `prepareDocument` yields
   inside `assemble` for the same take (compare encoded JSON); new fields
   round-trip and decode when absent; `MultitrackRenderTests`: a document
   with `musicMix = "wizard"` renders the same audio as `overlayMusic` on
   the same input (compareDecoded audio + timing).
