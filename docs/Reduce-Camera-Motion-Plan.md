# Reduce camera motion: measure the recording camera's shake, zoom in, counter it

Date: November 3, 2026. Status: implemented November 3, 2026 (Claude). Verified by unit tests and a Debug build; not yet watched on real footage.

## Why

The Camera row's "Steady" toggle only slowed the tracking camera down (the
`steady` tuning: tiny dead zone, slow smoothing), which hides slow pans but
not hand-held shake: the crop follows the person at 0.15 s cadence while the
whole picture wobbles several times a second. The user asked for the toggle
to be renamed "Reduce camera motion" and to do exactly that: examine the
footage ahead of time, find the stretches with too much camera motion, and
zoom in or out there so the crop can cancel the shake.

## What it does

1. **Measure.** While `CenterStageService.trackPeople` decodes the clip for
   people tracking, a `CameraMotionMeter` (Vision
   `TrackTranslationalImageRegistrationRequest`, region of interest = the
   feed) reports the content shift between consecutive frames as fractions
   of the feed's width and height (`CameraMotionSample`). This happens only
   when the tuning asks for it (`Tuning.stabilizes`, set on `steady`).
2. **Profile.** `CameraMotionPlanning.profile` integrates the shifts into a
   drift path, removes a straight line fitted over ±1 s (intended pans stay;
   anything that sways faster than that is shake), and keeps the remainder as
   the shake. A 1 s envelope of that shake marks shaky stretches
   (`threshold` 0.4 % of the frame); calm footage returns no profile and the
   path is exactly what it was before.
3. **Zoom and counter-move.** `CameraMotionPlanning.stabilized` post-processes
   the smoothed camera path: at every keyframe, and at 30 Hz (the measurement
   cadence) inside shaky stretches, the crop is shrunk just enough (per axis, capped at 8 % of the
   frame per side, never under the tuning's minimum crop height) to leave a
   margin equal to the smoothed shake envelope, then shifted by the shake so
   the content stays put, clamped to the frame. Faces are re-checked with
   `FaceGuard` after the move. The margin ramps in and out with the envelope,
   so the zoom does not jump at section edges. A crop that already has room on
   an axis (a 9:16 crop inside a 16:9 frame has horizontal room) keeps its
   size on that axis.
4. **Shot changes and re-framing.** Many sources are already edited: they
   cut between angles and push in digitally. The meter compares a coarse
   luminance grid of the feed frame to frame; a jump far above the recent
   changes is a shot change (`CameraMotionSample.cut`). A cut is not shake:
   the drift continues from where it was and nothing within half a second of
   the cut counts toward the envelope. In the camera path a cut makes the crop
   jump to the new framing at the cut time (two keyframes at one time, which
   the export and preview treat as a cut) instead of gliding across it. A
   re-frame without a cut (a digital zoom, the subject moving far) is caught
   up with `Tuning.reacquireSmoothing` while the crop is more than
   `reacquireDistance` of the frame width or a quarter of its height off,
   then the slow glide resumes. Both only apply under the stabilizing tuning.
5. **Report.** The tracking log gains one line: how many shaky stretches,
   how many seconds, and the largest shake as a percent of the frame.

## Where it lives

- `Services/CameraMotionPlanning.swift`: pure, tested (`CameraMotionPlanningTests`).
- `Services/CameraMotionMeter.swift`: the Vision wrapper, tested with synthetic
  shifted frames so the sign of the shift is pinned (`CameraMotionMeterTests`).
- `Services/CenterStageService.swift`: `Tuning.stabilizes`, the meter in the
  decode loop, `cameraPath(from:motion:)`, the fixture entry takes `motion`.
- `Views/Wizard/FramingRows.swift`: the toggle reads "Reduce camera motion".
  The stored key stays `Framing.steady` / `CropRecipe.steady` / camera name
  `steady`, so saved requests, recipes and the feed path cache identity keep
  working; `MultitrackRenderer.framingVersion` is bumped so old cached paths
  are re-tracked.

## Not done

- No rotation or scale compensation: translation only (that is what hand-held
  shake mostly is at these zoom levels).
- Fighter focus keeps its fast camera; the toggle is hidden there as before.
