# Effects — per-area looks and filters for the Builder

September 12, 2026. Plan for visual effects (black and white, film looks,
blur, vignette, grain, and so on) that apply per crop area on the Builder
timeline, render identically in the export and the Exact Preview, and are
scriptable. Nothing here is implemented yet; the LUT files it relies on are
already in the tree (see E9).

## Problem

The Builder can crop, place, caption, fade and speed-change footage, but it
cannot change how footage looks. A common short-form pattern is a split
layout where one area is graded differently from another (a black-and-white
reaction cam under a colour main feed, a blurred background copy behind a
sharp foreground, a warm archive clip next to a cool live one). Today the
only "Effects" the app knows are transitions, and every area of every layout
renders the source pixels as they are.

## Research findings that shape the design

- **Export is ffmpeg only.** `MultitrackRenderer.compositeLayeredSegment`
  builds one `-filter_complex` graph per segment: each placement is cropped
  and scaled to its area, masked with a gray PNG through `alphamerge`, then
  composited with a chain of `overlay` filters. Speed is `setpts`, fades are
  `fade` chains applied after the mask. An area effect is one more filter on
  the per-placement chain, inserted where `v{index}` is produced, before
  the mask and the fades.
- **Exact Preview already runs that same graph** (`renderBuilderExactPreview`
  with `preview: true`), so an ffmpeg-only effect is pixel-identical there
  with no extra work. Fast Preview and the poster-frame PreviewPane use
  `AVMutableComposition` and SwiftUI layout with no filters; they already
  skip crops, captions and transitions, so they may skip effects too, with a
  visible "not shown in Fast Preview" note. A CoreImage approximation is a
  later, optional phase.
- **Per-area settings already exist.** `TimelineDocument.trackSettings[i]`
  is the per-track slot, and `CropLayoutRef.area(forTrack:)` maps track
  index to area index. Effects live there. Per-clip overrides mirror
  `TimelineClip.cropXFrac`.
- **ffmpeg 8.1.2 on this machine** (Homebrew GPL build) has every filter the
  catalog needs: `hue`, `huesaturation`, `colorchannelmixer`, `curves`,
  `eq`, `colorbalance`, `colortemperature`, `lut3d`, `haldclut`, `gblur`,
  `unsharp`, `vignette`, `noise`, `pixelize`, `rgbashift`, `chromashift`,
  `negate`, `edgedetect`, `tmix`, `hflip`, `tpad`, `reverse`, `zoompan`,
  `geq`. All were smoke-rendered on September 12, 2026. The static fallback
  build that `ToolInstaller` downloads must be checked for `pixelize`
  (added in ffmpeg 6); the plan keeps a `scale` double-pass fallback.
- **No new runtime library is needed.** CoreImage covers a live preview if
  one is ever wanted; MetalPetal and GPUImage3 have had no commits since
  2024, and Harbeth (active) would add a second filter DSL for nothing the
  app cannot already do. The one asset worth pulling in is a LUT pack:
  **YahiaAngelo/Film-Luts** is MIT, 296 `.cube` files generated from G'MIC
  film emulations. Thirteen of them are now in `ClipBuilder/Resources/LUTs`
  with the licence file beside them (1.7 MB, LUT size 13).
- **Naming.** The sidebar's "Effects" screen shows transitions. This plan
  calls the new thing **Looks** in the UI ("Look" for a single preset) and
  `effect` in the data model and scripting surface, and renames the existing
  screen to **Transitions** as part of E5 so the two never collide.

## Decisions

- **E1. Where an effect lives.** `TrackSettings.effect: EffectSpec?` is the
  per-area default: every clip placed in that area gets it. `TimelineClip
  .effect: EffectSpec?` overrides it for one clip (`nil` = inherit, an empty
  spec = "none, even if the area has one"). The cropping row's crop blocks
  are not involved: an area is the same area under every layout that has
  it, and the Screen row already tells the user which area a track feeds.
- **E2. What an effect is.** `EffectSpec` is a small Codable value: a
  preset id (`"bw"`, `"sepia"`, `"lut:kodak_t-max_400"`, …) plus an optional
  parameter dictionary (`intensity`, `sigma`, `levels`, …) and an
  `intensity` 0–1 that mixes the effect with the untouched frame (ffmpeg
  `blend=all_mode=normal:all_opacity=`, so every look can be dialled back).
  Decoding uses `decodeIfPresent` with defaults like the rest of
  `TimelineModels`, and the JSON keys are snake_case (`effect`,
  `preset`, `params`, `intensity`) so the Python-era schema stays readable.
- **E3. Catalog is data, not code paths.** One `EffectCatalog` table maps
  preset id → display name, group, parameter definitions with ranges and
  defaults, the ffmpeg filter builder, and (later) the CoreImage builder.
  Everything else (inspector picker, popover, scripting enum, JSON schema,
  docs table, tests) is generated from that table, the way
  `TransitionCatalog` and `BuilderCommandCatalog` already work.
- **E4. Render insertion.** In `compositeLayeredSegment`, after the
  placement's crop/scale chain produces `v{index}` (or each
  `v{index}_{crop}` for free crops) and before the mask and fade steps,
  append `EffectCatalog.filter(for: spec, width:height:)`. Effects that need
  a second input (LUT files, grain) are plain filters with file arguments;
  the `.cube` path is the bundle resource path, escaped the same way the
  mask PNG paths are. `RenderSegmentCache.rendererVersion` bumps to
  `multitrack-segment-v4` because the per-clip chain changes.
- **E5. UI.** (a) `TrackSettingsPopover` gains a **Look** picker after
  Captions, with the preset's parameter sliders under it. (b) The clip
  inspector gains the same picker in a **Look** section with an "Inherit
  from area" default. (c) A **Looks** browser in Resources shows every
  preset as a looping sample rendered from the shared test clip, the way the
  transitions screen does; the current "Effects" sidebar item becomes
  **Transitions**. (d) The cropping row's block diagram tints an area that
  carries a look, so the timeline shows which areas are graded.
- **E6. Scripting.** `set_track_effect(track, effect | null, params?)` and
  `set_clip_effect(clip, effect | null, params?)`, validated against the
  catalog (`choice(preset, EffectCatalog.ids)`, params by the preset's
  ranges), applied through `updateTrackSettings` / `updateClip`, exposed in
  the `layouts` query (each area row gains `effect`) and the timeline and
  clips query rows, added to `BuilderCommandCatalog` so the JSON schema,
  the Scriptable Builder plan table and the JavaScript header pick them up.
  Local parser phrases: "make track II black and white", "remove the look
  from this clip", "apply <look> to area 2".
- **E7. Preview honesty.** Fast Preview and PreviewPane show a small "Look
  not shown" badge on an area that has one until the CoreImage phase lands.
  Exact Preview is the reference. This follows the parity rule already
  recorded for the Builder: nothing may claim "applied" that the export
  does not honour.
- **E8. Motion effects are out of scope for v1.** Reverse, freeze frame,
  Ken Burns and shake change timing or geometry, which the segment planner
  owns; speed already exists as `TimelineClip.speed`. They get their own
  plan once looks ship. The catalog reserves a `motion` group for them.
- **E9. LUTs ship with the app.** Thirteen curated `.cube` files from
  Film-Luts (MIT) under `ClipBuilder/Resources/LUTs` with
  `LICENSE-Film-Luts.txt`. Users can add their own `.cube` files through a
  new **LUTs** resource folder (`AssetKind.luts`) that syncs with the Drive
  home like music and images; the catalog lists bundled and user LUTs under
  one `lut:<name>` id space, user files winning on a name clash.

## Catalog (v1)

Every row is rendered by ffmpeg; the CoreImage column is for the optional
live-preview phase. `I` is the 0–1 intensity mix.

| Id | Look | Group | ffmpeg | CoreImage |
|---|---|---|---|---|
| `bw` | Black & White | Looks | `hue=s=0` | CIPhotoEffectMono |
| `noir` | Noir (contrasty B&W) | Looks | `hue=s=0,eq=contrast=1.35` | CIPhotoEffectNoir |
| `sepia` | Sepia | Looks | `colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131` | CISepiaTone |
| `faded` | Faded / matte | Looks | `curves=preset=lighter,eq=contrast=0.85:brightness=0.04` | CIColorControls + CIToneCurve |
| `vivid` | Vivid | Looks | `eq=saturation=1.45:contrast=1.08` | CIVibrance |
| `warm` | Warm | Looks | `colortemperature=temperature=4500` | CITemperatureAndTint |
| `cool` | Cool | Looks | `colortemperature=temperature=8500` | CITemperatureAndTint |
| `vintage` | Vintage film | Looks | `curves=preset=vintage,vignette=angle=PI/5,noise=alls=10:allf=t+u` | CIPhotoEffectTransfer + CIVignette + grain |
| `invert` | Invert | Looks | `negate` | CIColorInvert |
| `duotone` | Duotone (params: shadow, highlight colours) | Looks | `hue=s=0,lutrgb=…` from the two colours | CIFalseColor |
| `lut:<name>` | Film LUT (13 bundled + user files) | Film | `lut3d=file=<path>` | CIColorCube |
| `brightness` | Brightness (−1…1) | Adjust | `eq=brightness=` | CIColorControls |
| `contrast` | Contrast (0.5…2) | Adjust | `eq=contrast=` | CIColorControls |
| `saturation` | Saturation (0…2) | Adjust | `eq=saturation=` | CIColorControls |
| `gamma` | Gamma (0.5…2) | Adjust | `eq=gamma=` | CIGammaAdjust |
| `temperature` | Temperature (2000…12000 K) + tint | Adjust | `colortemperature=temperature=:mix=1` | CITemperatureAndTint |
| `vignette` | Vignette (strength) | Adjust | `vignette=angle=` | CIVignette |
| `sharpen` | Sharpen (0…2) | Detail | `unsharp=5:5:<amount>` | CISharpenLuminance |
| `blur` | Blur (sigma 0…20) | Detail | `gblur=sigma=` | CIGaussianBlur |
| `pixelate` | Pixelate (block 4…40) | Stylize | `pixelize=w=:h=` (fallback `scale` down/up with `neighbor`) | CIPixellate |
| `posterize` | Posterize (levels 2…10) | Stylize | `lutrgb=r='trunc(val/S)*S':g=…:b=…` | CIColorPosterize |
| `grain` | Film grain (0…40) | Stylize | `noise=alls=:allf=t+u` | CIRandomGenerator composite |
| `rgbsplit` | RGB split / glitch (px 2…20) | Stylize | `rgbashift=rh=:bh=-` | three CIAffineTransform copies |
| `vhs` | VHS | Stylize | `chromashift=cbh=4:crh=-4,noise=alls=14:allf=t+u,huesaturation=saturation=-0.2` | composite |
| `edges` | Edges / cartoon | Stylize | `edgedetect=mode=colormix:high=0.4:low=0.2` | CIComicEffect |
| `mirror` | Mirror (left half mirrored) | Stylize | `crop=iw/2:ih:0:0,split[l][r];[r]hflip[rf];[l][rf]hstack` | CIAffineTransform composite |

Reserved for the motion plan (E8): `freeze`, `reverse`, `motionblur`
(`tmix`), `kenburns` (`zoompan`), `shake` (`geq` jitter, never `vidstab`).

Parameter defaults live in the catalog; every preset also accepts
`intensity` (default 1). Intensities below 1 render as
`split[a][b];[b]<effect>[e];[a][e]blend=all_mode=normal:all_opacity=I`.

## Phases

1. **Model + catalog + render** (no UI). `EffectSpec`, `TrackSettings.effect`,
   `TimelineClip.effect`, `EffectCatalog` with the v1 table and ffmpeg
   builders, insertion in `compositeLayeredSegment`, cache version bump,
   LUT resource lookup. Tests: pure filter-string assertions per preset in
   `MultitrackRendererPlanningTests`; one integration render per group in a
   new `EffectRenderTests` using the `BRollRenderTests` pixel-probe pattern
   (solid-colour lavfi source → `bw` asserts R≈G≈B, `invert` asserts
   255−value, `lut:` asserts a changed but stable pixel, `blur` asserts an
   edge pixel moved toward the mean).
2. **Scripting.** The two commands, validation, catalog entries, query rows,
   parser phrases, docs table, JS header regeneration, schema tests.
3. **UI.** Track popover picker with parameter sliders, clip inspector Look
   section, cropping-row tint, "Look not shown" badges in Fast Preview and
   PreviewPane, sidebar rename to Transitions, new Looks browser with
   rendered samples (samples rendered once per preset through the real
   pipeline and cached under `data/.cache/looks`).
4. **User LUTs.** `AssetKind.luts`, Resources > LUTs folder with import,
   Drive sync through the existing asset-sync plan, catalog merge.
5. **Live preview (optional).** CoreImage builders in the catalog and an
   `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)` path in
   `TimelinePreview` that applies each area's look inside the area mask;
   remove the "Look not shown" badges when it lands.
6. **Motion effects** (separate plan): freeze, reverse, Ken Burns, shake.

## Not covered

- Per-crop-block effects (a look that changes when the layout changes) —
  E1 keys looks to areas and clips, which covers the split-layout case that
  motivated this; a time-ranged "adjustment layer" is a possible later step.
- Keyframed parameters (a blur that ramps) — parameters are constant per
  clip in v1.
- The static ffmpeg fallback build's filter list has not been checked for
  `pixelize` and `colortemperature`; phase 1 must probe `ffmpeg -filters`
  once at launch and hide catalog rows whose filter is missing.
