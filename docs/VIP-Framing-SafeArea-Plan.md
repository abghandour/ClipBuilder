# VIP rotation and hold, face-safe framing, and "Safe area only"

Date: October 21, 2026. Status: phases 1–3 implemented, Debug build passes, suites green; phase 4 live verification pending.

## Goal

Three fixes from the user's review of VIP focus and VIP B-Roll Focus
(October 21, 2026):

1. With several VIPs the picture must rotate between them calmly: a new VIP
   every 6 s while a non-VIP talks, and no shot shorter than 4 s, so VIPs
   never flash past.
2. The person in focus is always centred and never cut: live face tracking
   inside the feed, with the crop pulling back near the feed edge rather than
   slicing the face. One render showed a VIP's face cut by a third.
3. An Overlays-tab toggle "Safe area only" with a platform picker beside it:
   captions and name tags are kept inside the chosen platforms' safe zones
   even when their position is Bottom/Top or a corner. Watermark and overlay
   templates are not affected.

Decisions taken with the user: rotate every 6 s with a 4 s minimum hold; live
face tracking inside the feed; toggle plus per-run platform picker defaulting
to the profile's render-settings list; captions and name tags only.

## Where we stand (uncommitted VIP work)

- `VIPRecipePlanning.events(segments:tiles:roster:turns:start:)` picks the
  VIP tile per talker segment: a VIP who talks takes the picture; otherwise
  the most recent VIP stays. There is no rotation and the only hold is
  `CropRecipe.minimumHold` (1.5 s) inside `CropRecipePlanner.segments`.
  `CropRecipePlanner.plan` turns the events into `TrackingSpan`s per feed
  (`Data/CropRecipe.swift` around line 490) and `BuilderStore.compose` splits
  them into speech-precise clips with `areaRegion` + `areaFocus`.
- `VIPBRollSchedule.breaks` places 2.5–4 s breaks on `rankedPeaks` (score
  order across feeds) with a 4 s gap; with two VIPs it can pick the same VIP
  repeatedly.
- Feed framing: `MultitrackRenderer` (around line 351) calls
  `AreaFramer.frame(source:start:duration:area:region:focus:tuning:)` for
  `areaRegion` clips with `tuning: .named(centerStageCamera)` (`fastAction`
  by default: `minCropHeightFraction 0.72`, `padding 1.5`, snappy). The feed
  is cut out, then `CenterStageService.reframeClip` tracks people inside it
  (`DetectHumanRectanglesRequest` with a `DetectFaceRectanglesRequest`
  fallback in `trackPeople`). `desiredCrop(forUnion:)` centres on the union
  of body estimates (`bodyEstimate(fromFace:)` = 2.6 face widths, 3.2 face
  heights, centred 42 % down the union) and clamps to the source. Nothing
  guarantees a face box stays inside the crop: a wide union (two people) or
  a body estimate reaching past the feed edge can leave the face at the crop
  edge. When tracking bails (`trackedShare < 0.1`) the fallback is a static
  window centred on `focus`, the roster portrait centre measured at
  `portraitAt`, often minutes away from the clip.
- Safe area: `RenderSettings.platformSafeArea` (`enabled`, `platforms`) is
  edited in `RenderSettingsControls` with `PlatformTargetsPicker`.
  `PlatformSafeArea.resolve(platforms:aspectRatio:)` gives the safe rect
  regardless of the flag. Since October 4 explicit caption positions use the
  frame edge (`CaptionRenderer.position(for:positionOverride:)`) and explicit
  tag corners skip the safe rect (`NameTagPlanner.plan`, `explicitCorner ==
  nil` guards); Auto uses `position(for:clipPosition:)` and the safe rect.
  `WizardNameTags.settings(options:captionStyle:)` builds the planner
  settings; `WizardEngine.extractPlannedClip` (around line 4042) renders
  captions with `renderer.position(for:positionOverride:)`. Express options
  come from `MiniWizardSettings.step2Options`; the full Wizard from
  `@AppStorage` in `WizardView.swift` and `WizardView+Look.overlaysFields`.
  `RunSummaryCard` lists the Overlays chips.

## Rules

- Pure scheduling and framing maths in `nonisolated` enums with tests next
  to them; no behaviour change for recipes other than `.vip` / `.vipBRoll`
  except the face guard, which applies to every tracked crop (it only acts
  when a face would be cut).
- New option fields are Optional / defaulted so saved presets, remembered
  settings and sync decode unchanged.
- The preview column must show the same framing and placement: it goes
  through `CropRecipePlanner` and the same `WizardOptions`, so it follows
  once the options carry the new fields.
- Controls visible in both Overlays tabs; `lineLimit(1)` + `fixedSize` on
  row labels; captions through `FormCaption`.

## Part 1: VIP rotation and hold

`VIPRotation` (`Services/VIPRotation.swift`), pure:

```swift
nonisolated enum VIPRotation {
    static let every = 6.0, minimumHold = 4.0, tail = 2.5
    struct Shot: Sendable, Equatable { var time: Double; var tile: Int }
    /// Which VIP feed is on screen when, over `range`. `segments` are the talker
    /// stretches; `vipTiles` in tile order; `turns` name who talks.
    static func shots(range: ClosedRange<Double>, segments: [CropRecipePlanner.Segment],
                      vipTiles: [Int], recentFirst: Int?) -> [Shot]
}
```

Rules, walked on the source clock from `range.lowerBound`:

- Start on the talker if the talker is a VIP, else on `recentFirst` (the
  last VIP who spoke before the range), else the first VIP tile.
- While the current talker is not a VIP: every `every` seconds since the
  current shot began, switch to the next VIP in tile order (round-robin,
  skipping the one on screen). One VIP: no rotation.
- When a VIP starts talking: switch to them only when the current shot has
  held at least `minimumHold`; otherwise switch when the hold elapses, if
  they are still talking then. A VIP who stops talking stays on screen
  until the next rotation tick (never cut away the moment they stop).
- No switch starts in the last `tail` seconds of the range; a switch that
  would leave the previous shot shorter than `minimumHold` is skipped.
- `VIPRecipePlanning.events` calls `shots` when `vipTiles.count >= 1` and
  returns them as events; `CropRecipePlanner.plan` passes
  `max(recipe.minimumHold, VIPRotation.minimumHold)` as the segments hold
  for `.vip` and `.vipBRoll`.
- VIP B-Roll Focus: `VIPBRollSchedule.breaks` takes `rotate: Bool`
  (true when more than one VIP tile): consecutive breaks alternate VIP
  tiles (a peak for the VIP shown in the previous break is skipped when
  another VIP has a peak inside the same eligible span; the even-spacing
  fallback round-robins tiles). Breaks keep 2.5–4 s and the 4 s gap.

Tests (`VIPRotationTests`): two VIPs and a host monologue of 20 s produce
shots at 0, 6, 12 (alternating); a VIP interjection at 2 s is deferred to
4 s; a VIP talking for 1 s at 5 s does not cut away at 6 s; no shot shorter
than 4 s in a random fixture; single VIP produces one shot; `.vip` plan
with two VIP tiles yields tracking spans no shorter than 4 s.
`VIPBRollScheduleTests`: with two tiles, consecutive breaks alternate.

## Part 2: face-safe framing

`FaceGuard` (`Services/FaceGuard.swift`), pure, in pixels:

```swift
nonisolated enum FaceGuard {
    static let margin = 0.12   // of the face box, each side
    static let headroom = 0.10 // of the crop height above the face
    /// The crop (same aspect) moved, then enlarged within `bounds`, so every
    /// face lies inside it with the margin and headroom.
    static func contain(_ crop: CGRect, faces: [CGRect], bounds: CGRect) -> CGRect
}
```

- `CenterStageService.cameraPath(from:)` applies `contain` to `desired`
  before smoothing (the faces of the in-focus targets at that frame; the
  `Target` gains `faces: [CGRect]` filled by `trackPeople` from the face
  detections it already makes), and again to `current` after smoothing, so
  smoothing can never lag a face out of frame. Growing the crop is the
  "pull back near the edge" behaviour; it is capped at the bounds.
- `Tuning.conversation` (analysisInterval 0.1, keyframeInterval 0.3,
  smoothing 0.12, deadZoneWidth 0.05, deadZoneZoom 0.08,
  minCropHeightFraction 0.6, padding 1.35): `MultitrackRenderer` uses it for
  `areaRegion` clips (feeds) instead of the fast-action default; the user's
  `centerStageCamera` choice still applies to full-frame clips.
- Static fallback: when tracking bails, `AreaFramer.frame(region:)` first
  tries `CenterStageService.faceCenter(source:at:)` (one
  `DetectFaceRectanglesRequest` on the feed at the clip start, then at
  +1 s) and uses it as the window centre, with `FaceGuard.contain` on the
  detected box; the roster `focus` is the last resort. Log which was used.
- `CropRecipePlanner.crop(tile:aspect:sourceAspect:center:)` (still cells
  and preview) centres with `headroom` when a face box is known: the
  planner passes the roster portrait box, not only its centre.

Tests (`FaceGuardTests`): a face at the right edge of a 16:9 feed with a
9:16 crop centred on the body is shifted so the face has its margin; a face
taller than the crop grows the crop to the bounds; two faces far apart grow
the crop to include both; a contained face returns the crop unchanged.
`CenterStageServiceTests` (pure parts): `desiredCrop` + `contain` on a
synthetic target keeps the face inside.

## Part 3: Safe area only

Model:

- `WizardStep2Options.safeAreaOnly: Bool?` and `safeAreaPlatforms:
  [SocialPlatform]?` (keys `safe_area_only`, `safe_area_platforms`), merged
  into `WizardOptions` the same way as `nameTagPosition`.
- `MiniWizardSettings.safeAreaOnly = false`, `safeAreaPlatforms: [String]?`
  (raw values; nil = profile list), remembered per profile, in presets.
  `step2Options` maps them. Full Wizard: `@AppStorage("wizard.safeAreaOnly")`
  and `"wizard.safeAreaPlatforms"` in `WizardView.swift`, through its options
  builder.
- `WizardOptions.resolvedSafeArea: PlatformSafeArea?`: when `safeAreaOnly`,
  `PlatformSafeArea.resolve(platforms: safeAreaPlatforms ??
  renderSettings.platformSafeArea.platforms, aspectRatio:)`; else the
  existing `PlatformSafeArea.resolve(renderSettings)`.

Placement:

- `CaptionRenderer` gains `safeAreaOnly: Bool = false`.
  `position(for:positionOverride:)` with `safeAreaOnly` routes every position,
  explicit or auto, through `position(for:clipPosition:)` (the safe-area
  clamp), using the explicit position as the clip position. `WizardEngine`
  and the preview compositor construct the renderer with `safeArea:
  options.resolvedSafeArea, safeAreaOnly: options.safeAreaOnly == true`.
  `twoRowBand` follows the same rule so tag planning sees the real band.
- `NameTagPlanner.Settings.safeOnly: Bool`: when true, the `explicitCorner ==
  nil` guards treat an explicit corner like Auto for the allowed rect (the
  corner still decides which corner). `WizardNameTags.settings` sets it from
  the options and uses `options.resolvedSafeArea` for `safeRect`.
- Builder timelines produced by the Wizard already carry positioned items;
  no Builder change.

UI, both Overlays tabs, after the Name tags block:

- Toggle "Safe area only" (help: "Keep captions and name tags inside the
  platforms' safe zones, even at Bottom, Top or a corner.").
- When on: `PlatformTargetsPicker` bound to the per-run platforms (initial
  value: the profile's render-settings platforms; clearing all falls back to
  the profile list) and a `FormCaption` "Captions and name tags stay clear
  of the chosen platforms' buttons and bars. Watermark and overlays are not
  moved."
- `RunSummaryCard` Overlays chips: "Safe area: Reels, TikTok".
- Preview column: nothing to add; it reads the options.

Tests: `MiniWizardSettingsTests` round trip and remembered defaults;
`WizardOptionsTests` step2 merge; `CaptionRendererTests`: Bottom with
`safeAreaOnly` and Instagram chrome lands above the footer, without it on
the frame edge; `NameTagPlannerTests`: explicit bottom-trailing corner with
`safeOnly` sits inside the safe rect; `WizardPreviewCompositeTests`: the
preview caption moves up when the toggle is on.

## Phases

1. `VIPRotation` + tests; `VIPRecipePlanning.events`, planner hold,
   `VIPBRollSchedule` alternation + tests.
2. `FaceGuard` + tests; `Target.faces`; `cameraPath` application;
   `Tuning.conversation` and the renderer's feed tuning; static fallback
   face detection; planner headroom.
3. Safe area only: options, settings, UI in both wizards, renderer and
   planner changes, summary chip, tests.
4. Verification: Debug build; live on a two-VIP podcast with VIP focus:
   VIPs alternate every 6 s during the host, nothing under 4 s; faces
   centred with headroom in every feed shot; with Safe area only and
   Instagram, captions at Bottom sit above the footer and a bottom-right tag
   above the buttons; the preview column matches.
