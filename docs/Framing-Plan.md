# Framing: one model for focus, cropping, scaling, feathering and layouts

Date: October 27, 2026. Status: final (v3). Reviewed by Codex on October 27, 2026; the user's decisions of the same day are folded in. Ready for Phase 0. Nothing implemented.

## What the user asked for

"A full review of the camera focus/cropping/scaling features. It's getting too
complicated and I'm not achieving the results I want. A new comprehensive plan
that supports focus (e.g. Center Stage), cropping, scaling the image, and
feathering (to mask black bars). Screen layouts with different areas for VIP,
B-roll and non-VIPs. Options vary by video type: fight videos mostly want
original framing and fighter focus (VIP)."

Decisions taken with the user on October 27, 2026:

- Bars are masked by a blurred, zoomed copy of the frame with a feathered edge
  between the sharp picture and the blur.
- The user picks a layout; the app fills its areas by role and switches who
  shows with the speaker.
- Manual framing is one draggable focus frame per run plus the layout choice;
  no per-clip overrides in this plan.
- The four interview controls (Punch in on, Zoom in/out, Pull back, Smooth
  moves/Cuts) are replaced by a smaller set. Old presets and remembered
  settings are converted to the new choices once; small picture changes on
  old presets are accepted.
- Fighter focus with no fighter tagged tracks the action (both fighters).
- Blurred fill has both a Feather and a Blur slider.
- Four built-in layouts ship: Split, PiP, Three stack, Screen + presenter.
- Fit and feathering (Phase 2) land before the focus frame (Phase 3).
- Lean per-kind matrix (below). Wizard first; the output timeline stores
  framing in one model the Builder can read, but no Builder UI work here.

## Where we stand (code survey of October 27, 2026)

Five mechanisms frame footage and only the render pipeline is shared:

1. Analyze-time Center Stage paths on scenes (`FramingService`,
   `SceneRecord.centerStagePathJSON`); generated clips decide per clip
   whether to replay them (`TimelineClip.centerStage`,
   `WizardEngine.swift` ~3470). `extractPlannedClip` (~4363–4440) replays
   the path, else auto-crops wide footage (`autoCropXFraction`), and only
   then falls back to `normalizeFilter`'s black pad. So a scene without a
   path is usually auto-cropped, not letterboxed; the two routes differ.
2. The `CropRecipePlanner` family (`Data/CropRecipe.swift`) for podcast,
   interview and VIP footage: 8 `Kind`s, slots with windows, paths, tracking
   regions and spans; `PodcastRecipeTimeline` → `BuilderStore.compose`
   (~742–782) → `MultitrackRenderer` (prepass ~306–460, placement
   ~1985–2110). Recipes already compose one recording into several
   screen-layout areas, and Express renders those documents through
   `ExpressPodcastRenderer`; only the explicit layout picker is Full-only.
3. Screen-crop layouts (`ScreenCropStore`, `CropBlockItem`, `AreaFramer`)
   with polygon masks generated as hard grayscale PNGs
   (`ScreenCropStore.swift` ~401–440).
4. The legacy wide treatment in `RenderEngine` (`WideTreatment`,
   `detectContentBox` = non-black bounds, `normalizeFilter` = scale-decrease
   + black pad).
5. Hand-set Builder framing (`areaWindow`, `areaRegion`/`areaFocus`,
   `cameraPath`, `freeCrops`). Free crops scale a chosen source rectangle to
   the destination; area windows assume a matching aspect.

What makes it complicated:

- Three settings answer "who is framed": `highlightFraming`
  (`CropRecipe.Kind`), `podcastFraming` (`original`/`followSpeaker`, plus the
  dead `splitZoom`) and the per-clip `centerStage` flag. "Original" lives in
  a different field from every other choice, so the UI splits and re-merges
  one string (`cameraFocusBinding`, `MiniWizardSettings.swift:164–169`) and
  guards repeat `highlightFraming == nil && podcastFraming != .original`.
- The interview sub-options (`interviewZoom`, `interviewZoomMoves`,
  `interviewCuts`, `interviewPunchIn`) are mapped into the recipe in three
  places (`PodcastRecipeTimeline.swift:23–26`, `WizardPreviewFraming.swift`
  81–84 and 100–103) and persist even for kinds that hide them.
- `framingCamera` (Smooth/Balanced/Fast) is a Full-wizard-only control that
  still reaches podcast renders through `ExpressPodcastRenderer`.
- Fit is a black pad (full canvas or the 1080×640 band) wherever the picture
  does not cover the canvas. No blur fill or feathering exists.
- `splitZoom` is migrated away on decode but still handled in
  `WizardEngine.swift` (~3500, ~4347), `PodcastFramingService` and
  `WizardPodcastTimeline`.
- Timing policies are scattered and differently named: VIP rotation
  interval 6 s, VIP minimum hold 4 s, tail protection 2.5 s
  (`VIPRotation.swift:5`), `CropRecipe.minimumHold` 1.5 s, interview glide
  0.8 s (`InterviewFocusPlanning.swift:238`). They serve different purposes
  and stay different; they just need one home.
- Preview framing is approximate on cache misses and uses the nearest
  keyframe for scene paths (`WizardPreviewFraming.swift:8, 119`).

The existing planners (`CropRecipePlanner`, `InterviewFocusPlanning`,
`VIPRecipePlanning`, `VIPRotation`, `FaceGuard`, `CenterStageService`,
`AreaFramer`) are reused, subject to the compatibility checks below. The
plan replaces the *choice* model on top of them and adds the two missing
capabilities (fit with feathering, role-typed layouts).

## The model

Two things, kept apart:

1. **`Framing`** is what the user asked for. It lives on `WizardOptions`,
   Express memory, presets and the Full wizard defaults.
2. **`FramingPlan`** is what a clip actually got. The planner resolves
   `Framing` plus the evidence available (people, turns, feeds, paths,
   dimensions) into a plan, and the output timeline stores the plan, not
   the request. A saved run reproduces its picture even when the AI choice,
   the roster, or a user layout changes later. Builder edits to a clip's
   framing fields win over the stored plan, as today.

```swift
// Services/Framing/Framing.swift — nonisolated, Codable, Hashable, Sendable
struct Framing {
    var subject: Subject = .auto        // who the camera follows
    var pullBack: Double = 0            // 0 = tight on the face … 1 = full source height (today's Pull back)
    var moves: Moves = .smooth          // glides or hard cuts between shots
    var fit: Fit = .fill                // what happens when the picture does not cover the canvas
    var feather: Double = 0.08          // fade width as a fraction of the canvas (blurred fill only)
    var blur: Double = 0.5              // 0 = light blur … 1 = heavy blur of the background (blurred fill only)
    var focusFrame: FreeCropRect?       // per-run frame dragged in the preview; oriented source fractions, before bar removal
    var layout: String?                 // ScreenCropLayout name, subject == .layout only

    enum Subject: String { case auto, original, centerStage, vipFocus, speakerFocus, layout }
    enum Moves: String { case smooth, cuts }
    enum Fit: String { case fill, blurredFill }
}
```

Every field is Optional at every persistence boundary (`WizardOptions`,
step-2 options, Express memory, presets, timeline JSON). `FreeCropRect`
gains `Hashable` (`TimelineModels.swift:1441`).

Subject, in terms of the planners that exist:

| Subject | What the viewer sees | Implemented by |
|---|---|---|
| `auto` | The app picks one of the kind's allowed subjects (never `auto` itself); the pick is saved on the take as the AI decision is today | `CameraFocusChooser` extended to return a `Subject`, limited to `FramingMenu.allowed`, provenance kept |
| `original` | The source as recorded, placed with `fit`; a focus frame makes it a static window | static plan → `MultitrackRenderer` default placement / `normalizeFilter` with the fit graph |
| `centerStage` | Live tracking of everyone in the picture, calm camera | `CenterStageService` `balanced` tuning; the focus frame bounds the tracking region |
| `vipFocus` | The VIP(s): tight while they talk or fight, rotation between VIPs, B-roll breaks when the kind has them; on fights with no VIP tagged, the action (both fighters) | podcast/interview: `CropRecipe.Kind.vip` / `.vipBRoll`; fight: a new fighter-tracking adapter (below) |
| `speakerFocus` | Whoever talks, VIP preferred; `pullBack` sets the shot, `moves` the transition | `CropRecipe.Kind.interview` with `InterviewFocusPlanning`; `.talker` when there is no VIP |
| `layout` | A screen layout whose areas are filled by role | `ScreenCropLayout` + `LayoutRoleFiller` (Phase 4) |

`FramingPlan` has three cases, so every subject can be expressed
(`CropRecipe` alone cannot express a static fit, general Center Stage, or a
multi-source layout):

```swift
enum FramingPlan {
    case `static`(window: FreeCropRect?, fit: Framing.Fit, feather: Double)
    case tracked(CropRecipe, region: FreeCropRect?, fit: Framing.Fit, feather: Double)
    case composed(layout: ScreenCropLayout /* snapshot */, areas: [AreaSegment], fit: Framing.Fit)
}
```

`FramingPlanner.resolve(framing:context:) -> FramingPlan` takes a
`FramingContext` (video type, source identity and dimensions, selected
range, canvas aspect, people roster, turns, feeds, stored paths, layouts).
It is the only place that turns settings into a recipe, replacing the three
copies of the interview mapping. Shot selection (who, how tight) and
transition style (glide, cut) are separate steps inside it.

### Per kind

Kinds are `VideoType` (fight, training, interview, podcast, recap, other),
not Express's `FootageKind` (Q&A, Highlights, Transcript, Fight metrics),
which is a flow, not a footage type. "Screen recording" is not a
`VideoType` today; it is added as `.screen` in Phase 4 and otherwise the
rows for `.other` apply. A mixed-source run (several recordings) uses the
first recording's type and the same `Framing` for all.

`FramingMenu.allowed(type:) -> [Framing.Subject]` and
`FramingMenu.default(type:)`, one pure table with a test:

| Video type | Subjects offered (default first) | Fit offered |
|---|---|---|
| Fight | `original`, `vipFocus` ("Fighter focus") | blurred fill, fill |
| Training | `original`, `centerStage` | blurred fill, fill |
| Podcast | `auto`, `speakerFocus`, `centerStage`, `layout`, `original` | fill, blurred fill |
| Interview | `speakerFocus`, `centerStage`, `layout`, `auto`, `original` | fill, blurred fill |
| Recap / other (talking head, Q&A) | `speakerFocus`, `layout`, `original` | fill, blurred fill |
| Screen (Phase 4) | `layout` (screen + presenter), `original` | blurred fill |

`original` is offered everywhere because the user may always want the
recording untouched. For fight and training the default fit is blurred fill
so Original never crops a landscape fight into portrait; the user can still
choose fill.

A subject is shown only once its implementation phase has shipped
(`layout` appears after Phase 4). A subject whose evidence is missing
(no turns for speaker focus, no VIP for podcast VIP focus) is shown
disabled with a one-line reason, and `auto` never picks it. Fights are the
exception: Fighter focus always works (see Fighter focus).

Rows shown per subject, nothing else:

- `original`: Fit; Blur and Feather sliders when blurred fill. Focus frame
  in the preview (static window).
- `centerStage`: Fit (+ Blur, Feather). Focus frame (tracking bounds).
- `vipFocus`: Pull back, Fit (+ Blur, Feather). Focus frame (tracking bounds).
- `speakerFocus`: Pull back, Moves (Smooth/Cuts), Fit (+ Blur, Feather).
  Focus frame.
- `layout`: Layout picker (`ScreenCropStore` list with role badges), Fit for
  areas whose feed does not cover them.

"Pull back" keeps its name and direction (0 tight, 1 full height), so the
slider the user knows does not flip. Express and the Full wizard share one
`FramingRows` view. The card label becomes "Framing".

### Migration

Old fields keep decoding. `Framing.legacy(from:)` runs once when no
`framing` is stored (Express memory, presets, Full wizard defaults, saved
run settings) and converts to the new choices. The user accepted that an old
preset may render slightly differently afterwards; nothing legacy is kept in
the model and the old fields are dropped from the UI and from new writes.

| Old | New |
|---|---|
| `podcastFraming == .original` | `subject = .original`, `fit = .fill` |
| `highlightFraming == .vip` / `.vipBRoll` | `.vipFocus` |
| `.talker`, `.interview`, `.talkerAndRest`, `.talkerAndPrevious`, `.talkerAndRotation` | `.speakerFocus`; `pullBack = interviewZoom` (default 0); `moves = interviewCuts ? .cuts : .smooth` |
| `.grid` | `.layout` with the built-in "Split" layout |
| nothing set | `.auto` |
| `interviewPunchIn`, `interviewZoomMoves`, `framingCamera` | dropped; the planner uses talker punch-in, `balanced` tuning for Center Stage and `conversation` for focus |

Known picture changes from the conversion, listed so they are not reported
as bugs: VIP punch-in on non-VIP speech becomes a talker close-up instead of
a two-shot; the three talker-and-* compositions become the single
speaker-focus picture; grid runs become the two-area Split layout.

## Scaling and feathering (Fit)

`fill` is today's crop-to-cover. `blurredFill` is defined as four
things decided before any destructive crop, and only then turned into
filters:

- the foreground window (source rectangle to keep sharp),
- the background source (the same timed source, same window or whole frame),
- the destination rectangle on the canvas (full canvas, the band, or a
  layout area),
- the mask (area polygon when inside a layout).

`FitComposer.graph(_ spec: FitSpec, labels:) -> FilterFragment` in
`Services/Framing/FitComposer.swift` emits:

1. Background: source scaled to cover the destination, `boxblur` with a
   radius of `blur` mapped to 0.5…4 % of the destination width (clamped
   2…60 px), darkened 25 %.
2. Foreground: source scaled to fit, centred.
3. Feather: an alpha ramp of `feather × destination width` (clamped
   0…0.2) on the edges that touch the bars only; generated as an RGBA PNG
   through the mask plumbing in `ScreenCropStore` (extended to write
   gradients, with the output size in the cache filename, which it omits
   today at `ScreenCropStore.swift:440`). The fragment contract includes
   the extra input, unique labels, pixel-format conversion and the mask's
   cache identity.

Wired into `RenderEngine.normalizeFilter`, `MultitrackRenderer`'s default
placement and band (the band becomes a fit onto the full portrait canvas,
so nothing above or below it stays black, `MultitrackRenderer.swift:2038`),
and `AreaFramer` before its aspect crop (`AreaFramer.swift:148`, so the
blur has the discarded content to show). Bumpers keep their current fit.
The preview composite gets a CoreGraphics twin (`FitDrawer`) checked
against ffmpeg on one frame with per-region SSIM: whole frame ≥ 0.98 and
each feathered seam strip ≥ 0.95, so a bad seam cannot hide.

Baked-in bars are stripped first where `detectContentBox` runs today; the
podcast document route skips detection (`WizardEngine.swift:4183`), so
Phase 2 adds it there, nil result = no strip.

## The focus frame

One rectangle per run in oriented source fractions of the uncropped
recording (what the preview shows before bar removal). The preview handle
reuses `PreviewComponentHandle` (outline moves, grips resize; aspect locked
to the canvas for `original`, free otherwise). Conversion to post-bar-strip
coordinates happens in the planner. Runs over several recordings apply the
same fractions to each.

Semantics by subject:

- `original`: static crop window. Rendered as a free crop
  (`MultitrackRenderer.swift:1993`), not as a full-screen `areaWindow`,
  because a standalone full-screen window does not enter area processing
  (`MultitrackRenderer.swift:1257`).
- `centerStage`, `vipFocus`, `speakerFocus`: tracking bounds. Stored paths
  are recomputed inside the bounds, not clipped, since explicit camera paths
  discard `areaRegion` (`MultitrackRenderer.swift:329`). Subjects outside
  the frame are ignored; if that leaves nobody, the planner falls back to
  the static window and the preview says so.
- `layout`: not offered.

The preview re-renders the still through the same planner, so the still and
the output frame agree; keyframe-nearest paths are an accepted approximation
noted in the preview, not a goal of this plan. The Framing row's Reset
(icon, disabled when nothing changed) clears the frame.

## Layouts with roles

`ScreenCropArea.role: Role?` (`vip`, `others`, `broll`, `screen`,
`presenter`; nil = filled by order). Built-in layouts ship with roles:
"Split" (top `vip`, bottom `others`), "PiP" (full `others`, corner `vip`
drawn last), "Three stack" (`vip`, `others`, `broll`), "Screen + presenter"
(`screen`, `presenter`). The Layouts editor gets a role picker per area.

`LayoutRoleFiller.plan(layout:context:) -> [AreaSegment]` returns timed
source segments per stable area id, each with source identity, source range,
framing (static window or tracked recipe), role and audio policy (program
audio always comes from the main recording; a visual role change never
changes audio). This is what `BuilderStore.compose` needs, because `Slot`
has no source identity and `compose` uses one source for all areas
(`CropRecipe.swift:157`, `BuilderStore.swift:742`).

Fill rules:

- `vip`: the VIP tile, tracked; `VIPRotation` when there are several.
- `others`: the current non-VIP talker; between turns the most recent one
  holds.
- `broll`: B-roll windows from the existing planner; while none plays the
  area shows the `others` feed.
- `screen` / `presenter`: explicit source assignment in the layout picker
  (the recording tagged as screen, the recording tagged as camera).
  Automatic discovery is deferred; `detectContentBox` cannot find a screen
  tile.

Fallbacks, all deterministic and shown in the preview as a note:

| Case | Result |
|---|---|
| no VIP tagged | `vip` area takes the current talker; `others` the previous talker |
| only one person | every people area shows that person; the layout is still honoured |
| silence at the start | areas take the first speaker of the run |
| no B-roll | `broll` area shows `others`, else `vip` |
| two areas with the same role | filled in area order with the next candidate |
| missing presenter / screen source | that area shows the main recording |
| layout deleted since the run | the stored snapshot in `FramingPlan.composed` renders; the picker shows "(missing)" |

Timing policies move into one `FramingHolds` namespace with their current
values and names (rotation 6 s, VIP hold 4 s, tail 2.5 s, recipe hold
1.5 s, glide 0.8 s); nothing is unified to one number.

The Full wizard's `WizardLayoutMode` (Single/Approved/Choose) stays for
multi-scene AI layouts and is hidden unless `subject == .layout`.

## Fighter focus

Fight footage has no speaker turns and the podcast VIP path tracks the face
nearest a stored position (`CenterStageService.swift:355, 430`), which does
not hold identity when fighters cross. `vipFocus` on fights uses a new
`FighterTrackingAdapter`: the VIP's People portraits seed the track, the
`fastAction` tuning drives the camera, a lost target widens to Center Stage
for the next 2 s and re-acquires from the portraits. Fights never go
through the podcast tag gates (`WizardPodcastTimeline.swift:10`). Without a
VIP tagged, "Fighter focus" tracks the action: the camera follows the
bounding box of both fighters (`CenterStageService` with the `fastAction`
tuning over the two largest tracked bodies), and the row's caption says
"Following both fighters. Tag a fighter in People to follow one." The
subject is therefore never disabled on fights.

## Phases

Each phase builds, passes its suites, and is usable on its own.

**Phase 0 – Model and migration (S).**
`Framing`, `FramingPlan`, `FramingMenu`, `Framing.legacy(from:)`,
`FramingHolds`. `WizardOptions.framing` (+ step-2 options, decoding,
merge), `MiniWizardSettings.framing` (+ memory key, preset bridge,
`AISettingsPreferences`), Full wizard `@AppStorage`, `TimelineClip.framingPlan`
(Optional). New fields are Optional at every persistence boundary; conversion
distinguishes "never set" (`auto`) from an explicit old choice and writes
the new fields once. Cache identities
(`prepassKey`, preview keys) include the plan. Tests: conversion table per
old value, per-type menu, preset round trip, memory key catalog, timeline
JSON round trip and equality.

**Phase 1 – One planner and the new rows (M).**
`FramingPlanner.resolve(framing:context:)` replaces the three interview
mappings and feeds `PodcastRecipeTimeline`, `WizardPreviewFraming`, and the
fight/training route in `extractPlannedClip` explicitly. `FramingRows`
replaces the Camera focus rows in Express and Full; the four interview
controls and the Framing camera picker go. `CameraFocusChooser` returns a
`Subject` within `FramingMenu.allowed`. `splitZoom` code is deleted. Only
`original`, `centerStage`, `vipFocus` (podcast/interview) and
`speakerFocus` are exposed in this phase. Tests: resolve per subject and
per converted old value matches the table above (golden recipes), chooser
restriction, rows per video type.

**Phase 2 – Fit and feathering (M).**
`FitSpec`, `FitComposer`, `FitDrawer`, gradient masks; wired into
`normalizeFilter`, `MultitrackRenderer` placement and band, `AreaFramer`
before its crop, the podcast route's bar strip, the preview composite. Fit,
Blur and Feather rows. Tests: fragment strings per spec; preview/ffmpeg twin
per-region SSIM; renders of landscape, portrait and square sources onto
9:16 (pillarbox and letterbox), feather 0 and 0.2, blur 0 and 1, a small layout area,
baked bars, two resolutions, cold and warm cache (`compareDecoded`).

**Phase 3 – Focus frame (M).**
`Framing.focusFrame`, preview handle, planner conversion to a free crop or
recomputed tracking bounds. Tests: rendered containment per subject
(decoded frames, not field assignment), nonzero source start, speed change,
empty intersection fallback, preview parity.

**Phase 4 – Layout roles and Fighter focus (L).**
`ScreenCropArea.role`, built-in layouts, editor role picker,
`LayoutRoleFiller` → `AreaSegment`s, `compose` taking per-area sources and
multi-area tracking spans, PiP layering, polygon-aware preview, Express
Layout picker, `.screen` video type with explicit source assignment,
`FighterTrackingAdapter` (VIP and both-fighters modes). Tests: filler on a
two-speaker fixture with a VIP, each fallback row above, audio unchanged
across visual switches, fighter re-acquire on a crossing fixture, the
both-fighters box on the same fixture.

**Phase 5 – One render route (L, optional).**
Every wizard clip goes through a cut document and `MultitrackRenderer`;
`extractPlannedClip`'s own replay/auto-crop path is deleted. Before deleting,
verify parity for source clocks (the transcript clock at
`MultitrackRenderer.swift:92` stays independent), captions, speed,
transitions, B-roll, overlays, saved paths and cache invalidation, and gate
on `build/performance-baseline*`.

No re-analysis of existing projects is required by any phase. Subjects that
need evidence a project lacks (people, turns, feeds) are disabled with a
reason rather than silently downgraded.

## Verification

- Unit: the suites above; `WizardPreviewCompositeTests` end-to-end stills.
- Render: `MultitrackRenderTests` per-frame SSIM fixtures for blurred fill
  and for a three-role layout.
- Live: one Express run per video type on the fixtures the earlier plans
  used, comparing the preview still with the output frame at the same time.

## Decisions (October 27, 2026)

1. Fighter focus with no fighter tagged tracks the action with both fighters.
2. Blurred fill has both a Blur slider and a Feather slider.
3. Old presets and settings are converted to the new choices once; small
   picture changes are accepted. No legacy field in the model.
4. All four built-in layouts ship: Split, PiP, Three stack, Screen + presenter.
5. Fit and feathering (Phase 2) come before the focus frame (Phase 3).
