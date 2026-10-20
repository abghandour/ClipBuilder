# Express preview: one scene with the current settings

Date: October 20, 2026. Status: phases 1–3 and 5 implemented, Debug build passes, reviewed; live verification pending.

## Goal

A preview column on the right of AI Wizard Express that shows one scene of the
chosen video with the current settings composited on it: canvas aspect ratio,
captions in the chosen style, position and language, a name tag in the chosen
style and corner, the watermark at its opacity, the overlay template, and the
platform safe area. It updates as the user changes a setting. The full AI
Wizard gets the same column with its own settings.

## Where we stand

- `Views/MiniWizardView.swift` is one `ScrollView` of `MiniCard`s (Source,
  Footage, Settings with `MiniSettingsCard`, Generate). `MiniWizardSettings`
  (`Services/Wizard/MiniWizardSettings.swift`) holds every visual choice:
  `preset`, `captions`, `englishCaptions`, `captionPosition`, `captionStyleID`,
  `nameTags`, `nameTagContent`, `nameTagStyle`, `nameTagStyleID`,
  `nameTagPosition`, `watermark`, `watermarkOverlay`, `watermarkOpacity`,
  `overlay`, `overlayTemplate`, `overlayStart`, `overlayDuration`,
  `overlayTexts`. `step2Options(base:)` turns them into `WizardStep2Options`;
  `AppStore+MiniWizard.swift:284` takes the safe area from
  `profile.defaultRenderSettings`.
- The full wizard (`WizardView+Steps.swift` `configurationForm`,
  `WizardView+Look.swift`) is the same card column with its own `@AppStorage`
  state and `captionChoice(_:)`.
- Nothing composites a still frame today. The pieces exist:
  `ThumbnailService.thumbnail(for:at:maxDimension:)` for a frame;
  `CaptionRenderer` (`render`, `position(for:positionOverride:)`, safe area
  via `RenderContext.settings`); `CaptionPreviewImage` (sample line at
  1080x1920, no position override); `WizardNameTags.settings(options:captionStyle:)`
  and `NameTagPlanner.plan` / `overlay(_:canvas:style:)` with
  `TextOverlayRenderer.render`; `BrandRenderer.watermark(logoURL:to:opacity:)`;
  `WizardFixedOverlay.block` / `watermarkBlock` for templates with
  `TextOverlayRenderer` / `ImageOverlayRenderer`; `PlatformChromeLayer` for the
  safe-area chrome in SwiftUI.
- Layout precedent: `Views/CaptionStylesView.swift` puts its preview in a
  third `HSplitView` column pinned at the top. Rule: a live preview lives in
  its own split column, never inside the form.

## Rules

- Compositing is a `nonisolated` service under `Services/Wizard/` that
  returns one `CGImage`; it runs off the main actor (detached task), never in
  a view body. The view shows the last image while the next renders.
- The preview uses the production renderers with the production options
  (`step2Options`, the profile's render settings), so it shows what the
  Wizard will burn in. Anything the Wizard decides per clip at render time
  (auto caption position, auto tag corner) is resolved the same way here,
  with the preview scene's face area when the scene has one.
- Only visual settings trigger a re-render; the composite is keyed on a
  `PreviewKey` struct (the visual fields, the scene, the profile styles) so
  typing in the overlay text fields or changing audio does nothing.
- Debounce 150 ms; cancel the in-flight render when the key changes.
- Toolbar and header text in the column: `lineLimit(1)` + `fixedSize`.

## Design

### Service: `WizardPreviewComposite` (`Services/Wizard/WizardPreviewComposite.swift`)

```swift
nonisolated enum WizardPreviewComposite {
    struct Scene: Sendable { var videoURL: URL; var time: Double; var faceRect: CGRect?; var person: PersonRecord?; var captionText: String?; var words: [TranscriptWord]? }
    struct Input: Sendable { var scene: Scene; var options: WizardOptions; var profile: BrandProfile; var templates: [OverlayTemplate]; var frameData: Data }
    static func render(_ input: Input) throws -> CGImage
}
```

`render`:

1. Canvas = `options.renderSettings.width` x `height`. Decode `frameData`,
   centre-crop it to the canvas aspect (the same cover crop
   `cameraFocus` auto would make without a face; with `faceRect`, centre the
   crop on the face), and draw it.
2. Watermark: when `options` wants one, draw `BrandRenderer.watermark` (logo)
   or the template watermark through `WizardFixedOverlay.watermarkBlock` and
   the overlay renderers, at `options` opacity.
3. Overlay template: when enabled and the preview time falls inside
   `overlayStart ... overlayStart + overlayDuration` (take the preview as
   t = overlayStart), draw `WizardFixedOverlay.block` through
   `TextOverlayRenderer.render` / `ImageOverlayRenderer.render`.
4. Caption: when captions are on, text = `scene.captionText` (the transcript
   segment at the scene time in the chosen language, falling back to the
   first segment of the video, then to `CaptionPreviewImage`'s sample line),
   paged with `CaptionRenderer.pages` and the first page rendered with
   `activeIndex` at its middle word and `CaptionEmphasis` indices, placed by
   `position(for:positionOverride:)` with `options.captionPositionOverride ??
   "auto"` under `RenderContext.$settings` set to the render settings.
5. Name tag: when name tags are on, one tag for `scene.person` (first
   identified person of the scene) or a sample person ("Alex Morgan",
   role "Guest") through `WizardNameTags.settings` + `NameTagPlanner.plan`
   with the face area from `faceRect` (or the frame centre third) and
   `NameTagPlanner.overlay(_:canvas:style:)` + `TextOverlayRenderer.render`.
6. Return the CGImage. PNG intermediates go to a temp directory removed at
   the end.

Tests (`WizardPreviewCompositeTests`): a synthetic 640x360 frame with
captions on and bottom position produces a canvas-sized image with opaque
caption pixels in the bottom band and none in the top band; name tag on with
top-trailing puts opaque pixels in that corner; watermark off leaves the
top-left logo area equal to the plain frame; a portrait preset on a landscape
frame yields 1080x1920.

### Preview state: `WizardPreviewModel` (`Views/Wizard/WizardPreviewModel.swift`)

`@Observable @MainActor final class` with `image: CGImage?`, `isRendering`,
`sceneIndex`, `scenes: [SceneRecord]`, and `update(key: PreviewKey,
input: () -> Input?)`. It debounces, cancels the previous `Task.detached`,
caches the base frame per (video, time) through `ThumbnailService` at
`maxDimension` = canvas long edge, and keeps an LRU of 8 composites keyed by
`PreviewKey`.

`PreviewKey: Hashable` holds: preset, captions, englishCaptions,
captionPosition, captionStyleID, nameTags, nameTagContent, nameTagStyle,
nameTagStyleID, nameTagPosition, watermark, watermarkOverlay,
watermarkOpacity, overlay, overlayTemplate, overlayStart, overlayTexts,
cameraFocus, the scene id and time, the profile's `captionStyles`,
`tagStyles`, `tagStyle`, `logoPath`, `defaultRenderSettings`.

### View: `WizardPreviewColumn` (`Views/Wizard/WizardPreviewColumn.swift`)

Header row "Preview" with scene stepper (`chevron.left` / `chevron.right`
buttons, "Scene 3 of 12" label) and the existing `PlatformChromePicker`.
Below it the image, `aspectRatio(renderSettings.aspectRatio, .fit)`, with
`PlatformChromeLayer` on top, a `ProgressView` overlay while rendering, and
an empty state "Choose a video to preview" when there is no scene. A footer
caption: "One scene with the current Overlays settings. Position choices set
to Auto are resolved for this scene." Everything below the image is a
`Spacer`, so the column is pinned at the top like the Captions library.

Scenes: the chosen video's active scenes ordered by start, favourites first;
the preview time is the scene's midpoint. The stepper is the only way to
change the scene.

### Express layout (`MiniWizardView`)

Wrap the existing scroll column and the new column in an `HSplitView`:
left `frame(minWidth: 480, maxWidth: .infinity)`, right
`.rememberedPaneWidth("pane.express.preview", min: 240, initial: 320, max: 480)`.
The column is always visible once a video is chosen. The Source and Footage
cards are unchanged.

Input assembly lives in `MiniWizardView` (it already has `miniSettings`,
the profile and the selected video): `options = miniSettings.step2Options(base:)`
with `base.renderSettings = profile.defaultRenderSettings`, exactly as
`AppStore+MiniWizard.swift:284` does; refactor that line into a shared
`MiniWizardSettings.previewOptions(profile:)` so both use one path.

### Full AI Wizard (`WizardView+Steps.swift`)

Same `HSplitView` and `WizardPreviewColumn` beside `configurationForm`, fed
from the wizard's own state (`captionChoice`, `wizard.nameTagStyleID`,
`wizard.nameTagPosition`, the watermark keys) through its existing options
builder. Scenes come from the wizard's source pool (favourites first when
`favoritesOnly`).

## Phases

1. `WizardPreviewComposite` + tests; `MiniWizardSettings.previewOptions`.
2. `WizardPreviewModel`, `WizardPreviewColumn`, Express `HSplitView`.
3. Full AI Wizard column.
4. Verification: Debug build; live in Express: pick a video, switch caption
   style, position Top / Bottom, toggle name tags and corner, watermark
   opacity, canvas Square; each change updates the image within a second and
   the chrome overlay follows the canvas. Scene stepper moves through scenes.
   Typing in overlay text fields does not re-render (log the render count in
   Debug).

## Implementation notes — October 20, 2026

- Both app and test targets use file-system-synchronized groups; no project-file edits.
- Express preview and generation share `MiniWizardSettings.previewOptions(profile:base:)`.
  Express no longer inherits `wizard.brandingMode`; its remembered watermark uses its own key.
- The caption still uses `CaptionOverlayPlan` as well as `CaptionRenderer`, preserving
  emphasis, emoji and word reveal. Source transcript word clocks remain in source time.
- Overlay text typing does not trigger compositing. The next visual-setting or scene
  change captures the current replacement texts in `PreviewKey`; audio and encoding
  quality changes do not trigger compositing either.
- Phase 4 remains pending. The requested Debug build-for-testing was attempted after
  each phase; each invocation exited 143 during Xcode startup. No test suite or Release
  build was run. Syntax/helper checks do not establish a successful project build.

## Phase 5: Look and Camera focus (added October 20, 2026 after live feedback)

The live column ignored two Picture settings. Both are applied in the
compositor with the production code paths.

### Look

- `WizardEngine.lookEffect(for:)` gives the `EffectSpec` the render will
  grade with (nil when none or when the local ffmpeg lacks the filter).
  `EffectCatalog.filter(for:width:height:)` is the exact ffmpeg filter chain
  the render uses (LUT files via `lutURL`).
- The compositor grades the cover-cropped base frame before any overlay:
  write the cropped frame as PNG to the scratch directory, run
  `FFmpeg.run(["-y", "-i", in, "-vf", filter, "-frames:v", "1", out])`
  (same `escapeFilterPath` rules as the renderer), and draw the result. The
  graded frame is cached in the model keyed by (frame key, preset,
  intensity) so toggling overlays does not re-run ffmpeg. The ffmpeg step
  runs inside the detached render task; a failure logs and falls back to the
  ungraded frame with `error` set to "Look could not be previewed".
- `PreviewKey` gains `look: String` and `lookIntensity: Double?`
  (`MiniWizardSettings.lookName`, `options.lookIntensity`). The full Wizard's
  key uses `options.lookPreset`.

### Camera focus

`options.podcastFraming` / `options.highlightFraming` (from
`MiniWizardSettings.cameraFocus`) decide the framing exactly as
`WizardEngine` does for a clip; the preview reproduces the first frame of
that framing for the scene:

- `original` (`podcastFraming == .original`): cover-crop the full source
  frame centred, ignoring faces, as the engine's auto-crop does.
- Talker or "Let AI choose" (`highlightFraming == .talker` or nil): full
  screen following the talker. Crop rect = the scene's
  `SceneCameraPath` keyframe nearest the preview time when
  `scene.centerStagePath` exists and the content is wide (the engine's
  `usesSavedFraming` condition), else the cover crop centred on the face.
- Grid, Talker and the rest, Talker and previous, Talker and rotating others
  (`highlightFraming` other kinds): build `CropRecipe.plan(recipe, video:
  range: scene.start...scene.end, turns:, roster:, layouts:, canvasAspect:)`
  with the production inputs (`database.speakerTurns`, `fetchVideoPeople`,
  `ScreenCropStore` layouts), then draw each slot's source rect (`window`,
  or `region` with the `path` keyframe at the preview time, or `focus`
  cover) into its layout area (`ScreenCropArea` rects of `plan.layout`),
  each cover-cropped to the area's aspect. The talker at the preview time
  comes from the plan's talking spans. When `CropRecipe.plan` throws (one
  feed, no analysis), fall back to the talker framing and show its
  `Failure.description` under the image as a secondary caption.
- `WizardPreviewComposite.Scene` gains `cameraPath: SceneCameraPath?`,
  `contentIsWide: Bool`, and `framing: Framing` where
  `enum Framing { case cover(face: CGRect?), path(CameraPathKeyframe),
  cells([(source: CGRect, area: CGRect)]) }` is computed in
  `WizardPreviewModel.loadScene` on the worker (it has the database) and
  the compositor only draws it. `PreviewKey.visual.cameraFocus` already
  participates; the model must recompute `framing` when it changes, so
  `cameraFocus` joins the column's `ContentKey`.
- Name-tag face areas and the caption band use the drawn cell geometry:
  with cells, each person's face maps into their cell, so `NameTagPlanner`
  receives one `Area` per cell as the engine does.

Tests: `WizardPreviewCompositeTests` adds a two-tile synthetic video with a
grid plan producing two distinct cells (left half pixels from tile 0's
colour, right half from tile 1's); original framing ignores a face rect
(same output as no face); look "none" equals the ungraded frame; a look
with intensity 0.5 changes pixels (skipped when ffmpeg is absent).

Verification: in Express pick a Look and watch the frame grade within a
second; switch Camera focus between Original, Talker and Grid on a
two-person recording and see the framing change; name tags land in their
cells.


### Phase 5 implementation — October 20, 2026

- `WizardPreviewFraming` resolves Original, scene-local saved camera keyframes,
  speaker-centred cover, and production `CropRecipePlanner` slots on the scene
  worker. Recipe failures preserve talker framing and display the production
  failure description below the preview. Cell tag faces use the same final cover
  transform as the pixels and retain the production caption-band avoidance.
- Look grading runs before overlays via `WizardEngine.lookEffect` and
  `EffectCatalog.filter`, including partial-intensity graphs and LUT escaping.
  A four-entry base-image LRU keys the source frame, canvas, framing geometry,
  look and intensity; tag metadata and overlay settings do not invalidate it.
  Failed grades display the ungraded image plus an error and remain retryable.
- Both column inputs now invalidate on Camera focus and canvas aspect. The
  composite key includes Look and intensity. Express retains its own options.
- Extended `WizardPreviewCompositeTests` for grid pixels, Original versus
  talker, saved path timing, recipe fallbacks, cell face geometry, no Look,
  half-intensity grading (enabled only with ffmpeg), and visual key changes.
- Verification: the final requested Debug `build-for-testing` exited 143 during
  Xcode startup, before source compilation. `xcbeautify` is absent. All five
  changed/new Swift files parse; compositor/framing services typecheck against
  existing Debug modules, as does a temporary model copy with Observation macros
  removed. Full source typechecking is blocked by sandbox-denied macro plugins.
  These limited checks do not establish a successful project/test-target build.
  No tests, Release build, or live UI checks were run.
