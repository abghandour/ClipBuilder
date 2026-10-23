# Interview focus: the VIP first, the interviewer still in the picture

Date: October 22, 2026. Status: implemented (phases 0–4); verified on the Tanner Boser interview by planning and frame crops, not yet by a full render.

## Goal

A new Camera focus, "Interview focus", for interviews and podcasts where a
VIP answers an interviewer. The picture prefers the VIP: tight on them while
they talk. While the interviewer asks, the picture does not leave the VIP;
it pulls back to a two-shot that keeps the VIP and brings in the
interviewer, ideally their face, at least part of them when the two sit too
far apart for one 9:16 frame. Moves between shots are slow pans and zooms,
not cuts, and the camera moves only when a speaker change is real and has
lasted: no twitching on interjections, no drift while nobody changes.

Requested by the user on October 22, 2026: "give preference to the VIPs but
still display some part of the interviewer interviewing (ideally some of his
face); the app can pan out or zoom in for a better angle; the camera should
not move unnecessarily."

## Where we stand

- Camera focus kinds live in `CropRecipe.Kind` (`Data/CropRecipe.swift`):
  `talker`, `vip`, `vipBRoll`, `grid`, `talkerAndRest`, `talkerAndPrevious`,
  `talkerAndRotation`. Every list of kinds is `Kind.allCases`
  (`Views/WizardCameraFocusPicker.swift`, `Views/Builder/ClipBrowserPane.swift:545`,
  the highlight prompt in `Services/PodcastHighlightFinder.swift:417`, the
  wizard prompt in `Services/WizardEngine.swift:1075`), so a new case appears
  everywhere once added. `CameraFocusChooser.allowedLayouts(feeds:hasVIP:)`
  gates `vip` and `vipBRoll` on a VIP being present.
- `CropRecipePlanner.plan` (`Data/CropRecipe.swift`) turns a recipe, the
  speaker turns and the roster into one `Slot` per layout area: a static
  `window`, a `path` of `CameraPathKeyframe`s, or a `region` plus `focus`
  for the live tracking camera. For a single camera `tiles(video:roster:)`
  makes one column per roster portrait, split midway between neighbours; a
  split recording uses its stored tiles.
- `VIPRecipePlanning` (`Services/VIPRecipePlanning.swift`) picks VIP tiles
  and `VIPRotation.shots` (`Services/VIPRotation.swift`) rotates between
  VIPs every 6 s with a 4 s minimum hold and a 2.5 s tail; the result is
  `TrackingSpan`s that `BuilderStore.compose` (`App/BuilderStore.swift:735`)
  turns into speech-precise clips, each tracking inside its feed with the
  `conversation` tuning (`CenterStageService.Tuning`, `Services/CenterStageService.swift:161`).
- Camera paths interpolate. `AreaFramer` (`Services/AreaFramer.swift:200`)
  writes each keyframe pair as a linear ramp in the crop filter; a hard cut
  is a hold duplicate one `CameraKeyframes.cutGap` before the next keyframe.
  So a slow pan or zoom is two keyframes a second or so apart with different
  rectangles; nothing new is needed in the renderer. Full-screen paths go
  through `MultitrackRenderer` (around line 321) when
  `CenterStageService.pathMatchesCanvas` holds, which requires every
  keyframe to have the canvas aspect within 3 %.
- Face evidence: `CropRecipePlanner.faceFocus(of:roster:)`
  (`Services/CropRecipePlanner+FaceFocus.swift`) gives the tile's face centre
  and the roster portrait box; `FaceGuard.contain` (`Services/FaceGuard.swift`)
  keeps faces inside a crop with margin and headroom;
  `CenterStageService.faceCenter(source:at:region:)` (around line 860)
  detects the largest face in a region of one frame.
- Interview footage in the user's library (October 22, 2026): "Tanner Boser
  Interview" is a single camera, 1920×1080, two tiles (columns 0–0.5 and
  0.5–1) with face centres at x 0.37 and 0.57; the roster has
  `tanner-boser` VIP (ai) and the host `dude` VIP off (user). Both faces fit
  one 9:16 crop at full height: a 9:16 window of a 16:9 source is 0.316 of
  the width. "Aljo - Ariel Helwani Interview" is single camera with one
  roster entry, so it has one tile and no two-shot to plan.
- Bug found on the way: the people pass stores portrait boxes as
  x=1, y=1, w=1, h=1 for several videos (videos 13 and 16 in the user's
  database). `Analyzer.detectPeopleOnly` (`Services/Analyzer.swift` around
  line 1090) clamps each value into 0…1, so a model answering in pixels
  saturates. Interview focus centres on faces, so this is a prerequisite.

## Decisions to take with the user

Stated as the defaults this plan builds unless the user says otherwise:

1. Single camera is the target. For a recording with separate feeds
   (split or grid), Interview focus behaves like VIP focus for the VIP's
   feed, and while the interviewer talks it shows a two-cell layout with
   the VIP large on top and the interviewer below ("Talker + 2" style is not
   it; use "50-50 Horizontal" with the VIP in the top cell). No panning
   exists between feeds.
2. Moves are pans and zooms of about 0.8 s. A cut is used only when the
   two shots do not overlap at all (the interviewer sits outside any frame
   that also holds the VIP), which cannot happen on a single camera where the
   two-shot always contains the tight shot.
3. One VIP per interview. With several VIPs the existing VIP rotation
   applies to the tight shot; the two-shot includes the interviewer and the
   VIP currently in focus.

## Rules

- Shots. Two rectangles at the canvas aspect, both inside the source:
  - Tight: the smallest crop that holds the VIP's face with `FaceGuard`
    margin and headroom, never narrower than 0.6 of the source height
    (`Tuning.conversation.minCropHeightFraction`), centred on the face.
  - Two-shot: the smallest crop that holds both faces with margin and
    headroom. When that needs more than the full source height, the crop is
    full height, keeps the VIP's face whole with margin, and extends toward
    the interviewer as far as the frame allows, so part of them is in the
    picture. The plan notes "Two-shot cannot hold both faces; the
    interviewer is partly in frame" so the log says why.
  - VIP placement fallback (October 22, 2026): a single VIP whose portrait
    lands on no feed is placed on the feed that speaks longest
    (`VIPRecipePlanning.placingUnplacedVIP`), with a plan note; the face
    sampler names feeds the same way.
  - Pull back (added October 22, 2026, after the user asked for a wider
    interview frame): `WizardOptions.interviewZoom` (0...1, "Pull back" slider
    under Camera focus in Express and the full wizard, saved per profile and
    in presets as `interviewZoom`) raises the tight shot's height from the
    0.6 minimum toward the full source height; the two-shot never drops below
    the tight shot, so at 100 % both shots are full-height columns: the tight
    one centred on the VIP, the two-shot slid toward the interviewer, and the
    move between them is a pan only. `CropRecipe.interviewZoom` carries it
    into the planner.
  - When the two-shot and the tight shot differ by less than the dead zone
    (centre shift under 5 % of the source width and height under 8 %
    different) the two-shot is used for the whole clip and the camera never
    moves. This is the "do not move unnecessarily" guarantee.
- Timing, on the source clock, from `CropRecipePlanner.segments` with the
  VIP hold (`VIPRotation.minimumHold`, 4 s):
  - The VIP talking means tight; anyone else talking means two-shot.
  - A move happens only when the new talker has held for `minimumTurn` (1 s)
    and the current shot has lasted at least 4 s. A shorter interjection by
    the interviewer never moves the camera; the VIP's own short reply inside
    an interviewer stretch never moves it either.
  - A move takes `InterviewFocusPlanning.moveSeconds` (0.8 s), starting at
    the speaker change: two keyframes, the old rectangle at the change and
    the new one 0.8 s later. The clip opens on the shot the first talker
    calls for, with no move in the first second.
  - No move starts inside the last 2.5 s (`VIPRotation.tail`).
- Framing inside a shot is static: a rectangle, not the live tracker. The
  rectangle is placed from face evidence sampled at the shot's start (phase
  3) and falls back to the roster portrait box and tile face centre.
- Pure logic goes in `nonisolated enum InterviewFocusPlanning`
  (`Services/InterviewFocusPlanning.swift`) with tests next to it; the
  planner integration stays inside `CropRecipePlanner.plan`; the only
  frame-decoding code is one call to `CenterStageService.faceCenter` per
  shot start, off the main actor, bounded to the number of shots.
- No model call is labelled AI: the chooser offers the kind to the model
  like every other; the kind itself is rules only.
- Nothing changes for the other kinds; `CropRecipePlannerTests` keep
  passing unchanged.

## Model

- `CropRecipe.Kind.interview = "interview_focus"`, name "Interview focus",
  summary "Tight on the VIP while they talk; a slow pull back brings the
  interviewer in while they ask." `layoutName` → full screen on a single
  camera, "50-50 Horizontal" with two or more feeds. `defaultSlots` →
  `[.vip]` full screen, `[.vip, .talker]` for two cells.
- `InterviewFocusPlanning`:
  - `struct Shot { kind: tight | twoShot; rect: FreeCropRect }`.
  - `static func rects(vipFace: CGRect, otherFaces: [CGRect], sourceAspect:,
    canvasAspect:) -> (tight: FreeCropRect, twoShot: FreeCropRect, note: String?)`.
  - `static func moves(segments:, vipTiles:, range:, hold:, minimumTurn:) ->
    [(time: Double, kind: Shot.Kind)]`, the shot changes after the timing
    rules.
  - `static func path(moves:, tight:, twoShot:, length:, moveSeconds:) ->
    [CameraPathKeyframe]`, with the dead-zone collapse to a single rectangle.
  - `static let moveSeconds = 0.8`, `deadZoneCenter = 0.05`,
    `deadZoneHeight = 0.08`.
- `AnalysisCheckpoint` and records are untouched. No schema change.

## Phases

0. Portrait boxes in pixels. In `detectPeopleOnly`, when any portrait value
   exceeds 1, divide x and w by the sampled frame width and y and h by its
   height (the frames come from `extractFrames` at the source size, so
   `video.width`/`video.height`) before clamping; log "Portrait box for
   <key> given in pixels; normalised". Test in `AnalyzerTests` or a new
   `PortraitBoxParsingTests` on the pure normalisation helper. Re-running
   People detection on the affected videos repairs their avatars.
1. Pure planning. `InterviewFocusPlanning` with tests: both faces fit →
   two-shot smaller than full height; faces too far apart → full-height crop
   anchored on the VIP with the note; dead zone → one rectangle, no
   keyframes beyond the hold; interjection under 1 s → no move; hold → a
   move waits for 4 s; tail → no move in the last 2.5 s; moves are 0.8 s
   ramps and never hold duplicates.
2. Recipe and wiring. The new `Kind`, `layoutName`, `defaultSlots`;
   `CropRecipePlanner.plan` builds the slot: full screen → `slot.path` from
   `InterviewFocusPlanning`, no `trackingSpans`, no `region`; two feeds →
   top cell `.vip` as today, bottom cell `.talker`. `CameraFocusChooser.allowedLayouts`
   offers it only with a VIP and one or two non-VIP people.
   `WizardCameraFocus.summary` and the pickers pick it up through `allCases`.
   `WizardPodcastTimeline.cutDocuments` and `PodcastRecipeTimeline.build`
   need no change if the slot is a plain path; verify the full-screen path is
   installed as `cameraPath` with `centerStage` true (BuilderStore.compose
   line 802 onward) and that `pathMatchesCanvas` accepts the rectangles
   (build them from the canvas aspect, round to 4 decimals as `crop` does).
3. Face refinement. At each shot start sample one frame and call
   `CenterStageService.faceCenter` inside the VIP's tile and the
   interviewer's tile; replace the portrait-derived boxes when a face is
   found; keep the portrait when not. Runs where the plan is applied (the
   Builder compose and the wizard timeline), not in the pure planner; the
   planner takes face boxes as input.
4. Live check on "Tanner Boser Interview": a Builder compose with Interview
   focus over a 40 s range with both speakers; expect the opening shot to
   match the first talker, one pull-back of 0.8 s when the host's question
   starts, no move on his short interjections, and the render to show both
   faces in the two-shot. Compare against VIP focus on the same range.

## Already-analyzed videos

No re-analysis is needed for the camera focus itself. Videos whose roster
portrait boxes saturated at 1 (phase 0) need the People detection stage run
again to get usable face boxes; until then Interview focus centres on the
tile face centre from the layout pass, which exists for Tanner Boser but not
for every single-camera interview.

## Pull back on the anchored two-shot — October 23, 2026

When both faces cannot fit in the canvas (people far apart in a 9:16
column), the "two-shot" is anchored on the VIP with the interviewer partly
in frame. It used to take the full source height regardless of Pull back,
so a clip where the interviewer talks never responded to the slider (seen
on "Tanner Boser Interview", clip 0:21–0:25: identical preview at 0 % and
100 %). `InterviewFocusPlanning.rects` now sizes that anchored shot with
the tight shot's zoom-following height (conversation height at 0 %, full
height at 100 %), keeps the VIP's roomy face inside, and leans toward the
interviewer. A two-shot that does hold both faces keeps its rule (never
below the tight height). Codex implemented; Claude reviewed, rebuilt and
re-pointed two tests whose fixtures assumed the old full-height anchor
(`InterviewFocusRecipeTests.closeFacesRemainStaticAndImpossibleTwoShotReportsWhy`,
`WizardPreviewCompositeTests.interviewPreviewFollowsTheScrubbedMomentAlongTheCameraPath`).
Tests: `InterviewFocusPlanningTests.distantFacesFollowPullBackAndKeepVIPWhole`,
`fullyPulledBackAnchoredShotCanCoincideWithTightShot`,
`WizardPreviewCompositeTests.interviewPullBackChangesAnchoredPreviewWhileInterviewerTalks`.

## Zoom in/out for focus — October 23, 2026

New toggle under Pull back (Express Picture tab and the full wizard's Camera
focus group): `CropRecipe.interviewZoomMoves`, `WizardOptions.interviewZoomMoves`
(Optional), `MiniWizardSettings.interviewZoomMoves` (memory field, preset
field `interviewZoomMoves`, defaults key `wizard.interviewZoomMoves` for the
full wizard, run-settings key). When on, `InterviewFocusPlanning.rects` returns
a wide shot centred where the tight shot is, opened to the full source height
and kept around the VIP's face, instead of the two-shot that leans toward the
interviewer. The moves between the two therefore zoom in place: in while the
VIP talks, out while the interviewer asks. Pull back still sets the tight
shot's height; at 100 % both shots coincide and the camera stays still. The
preview builds its recipe from the same options, so it shows the same shot.
Tests: `InterviewFocusPlanningTests.zoomMovesKeepTheWideShotCentredOnTheVIP`,
`WizardPreviewCompositeTests.interviewZoomMovesKeepThePreviewOnTheVIPWhileTheInterviewerTalks`,
`MiniWizardSettingsTests.zoomMovesMapsToTheOptionsAndRoundTripsThroughMemoryAndPresets`.

Update, October 23, 2026 (same day): with the toggle on, Pull back is hidden
in both wizards and ignored by the planner (the tight shot is the
conversation height). The zoomed-out shot holds everyone when both faces fit a
frame (the ordinary fitting two-shot); only when they cannot share a frame does
it open to the full height around the VIP, with the note "Both people do not
fit one frame; zooming out around the VIP". Tests:
`InterviewFocusPlanningTests.zoomMovesIgnorePullBackAndOpenAroundTheVIPWhenPeopleCannotShareAFrame`,
`zoomMovesKeepEveryoneOnScreenWhenTheyFit`.
