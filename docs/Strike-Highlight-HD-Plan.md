# HD strike highlight: follow the limb's contour

Date: 2026-11-21. Status: asked for by the user, not implemented.

## What the user asked for

An option to make a strike's highlight "HD": the overlay follows the outline of the
attacker's limb in the picture instead of the plain green band. It is a second step the
user asks for, never the default, and actions that have it carry an HD flag.

## Ground truth

| Thing | Where |
| --- | --- |
| Track, keyframes, highlight (limb polyline, target, radius), sampling, `version`, `step`, `fade` | `Services/StrikeHighlightRules.swift` |
| Finding a track from body poses | `Services/StrikeHighlightFinder.swift` (uses the Swift Vision API, `HumanBodyPoseObservation`) |
| Drawing (player overlay AND burn-in share it) | `Services/StrikeHighlightPainter.swift`, `Views/StrikeHighlightOverlay.swift`, `Services/StrikeHighlightBurn.swift` |
| Saved tracks: `strike_highlights.track_json` (Codable `Track`), local to this Mac, tied to the event generation | `Data/Database+Fights.swift`, `Data/Models.swift` (`StrikeHighlightRecord`) |
| Batch marking job to copy the shape of | `AppStore.markStrikes(video:)`, `Services/StrikeHighlightMarker.swift` |
| Popup | `Views/Fight/FightActionDetailSheet.swift`, `FightActionPreview.swift`, `FightActionPlayback.swift` |

## Design

- **Data.** `StrikeHighlightRules.Highlight` gains `var contour: [CGPoint]? = nil`: the
  limb's outline as a closed polygon, 0…1 of the frame, top-left origin, always exactly
  `StrikeHighlightRules.contourPoints` (48) points, starting at the point nearest the
  limb's first joint and running clockwise. Optional, so every saved track still decodes.
  A track is HD when any keyframe has a contour (`Track.isHD`). `drawable(_:)` keeps the
  contour. `StrikeHighlightRules.version` is NOT bumped (a bump would throw away every
  saved track).
- **HD keyframes are dense.** The plain track has a keyframe per `step`. Making it HD
  replaces the keyframes between the track's start and end with one per source frame
  (capped at 30 a second), each with limb, target and radius interpolated from the plain
  track by the existing `sample` rule and its own contour. Fixed point count and fixed
  start make linear interpolation between two contours valid, so `sample` interpolates
  contours when both neighbours have one and drops the contour otherwise.
- **Finding the contour** (`Services/StrikeHighlightContour.swift`, media half, and pure
  rules in `StrikeHighlightContourRules`):
  1. Decode the frame at the keyframe time (`ThumbnailService.jpegFrames`, maxDimension
     960, tolerance 0, as the finder does).
  2. Person masks from Vision's person INSTANCE mask request (Swift API). Pick the
     instance that covers the most points sampled along the limb polyline. If the
     instance request is unavailable or finds nobody, fall back to the single
     person-segmentation mask.
  3. Limb region: a capsule around the limb polyline. Radius is a share of the attacker's
     apparent size: use the track's `radius` (already scaled to the body) times 1.6 for
     an arm and 2.2 for a leg, and extend the last segment past the wrist or ankle by 60%
     of its length so the fist or foot is inside.
  4. Outline: the largest connected region of (mask AND capsule), its boundary traced
     (pure function over a bitmap: marching squares or Moore neighbour tracing),
     simplified, then resampled to 48 points by arc length from the start rule above.
  5. A frame fails when the region is smaller than 15% of the capsule's area or larger
     than 95% of it at mask resolution (no person there, or the mask is the whole
     capsule: nothing learned). A failed frame gets no contour.
  6. HD is saved only when at least 60% of the frames between `contact − 0.3 s` and
     `contact + 0.15 s` have a contour. Otherwise nothing is saved and the user is told
     "The limb's outline could not be found for this strike".
- **Drawing.** `StrikeHighlightPainter.draw`: with a contour, fill the polygon (green,
  alpha 0.35), stroke its edge (alpha 0.9, width `max(1.5, radius * 0.08)`) with the same
  glow; no band. Without one, as today. The red impact ring is unchanged. Overlay and
  burn-in use the painter, so both get HD with no further change; check that
  `StrikeHighlightBurn.sequences` samples often enough that a dense track is not thinned
  to the old step.
- **Storage.** The HD track overwrites the row's `track_json` (same row, same generation
  rules: write only if the event generation is current and the event row is unchanged, as
  `saveStrikeHighlights(expectedEvent:)` does). A re-score, a correction of that action,
  or Mark strikes with `replacing` drops it like any highlight; the flag then goes.
  No new table, no sync.
- **Jobs.** `AppStore.makeStrikeHighlightsHD(video:events:)` runs as an `AppJobs` job
  (kind `.fightScore`, title "HD highlight — <file>"), off the main actor, one strike or
  all strikes that have a plain track. Stoppable; what was finished stays saved. Bumps
  `strikeHighlightRevision` after each saved strike. Guarded like `markStrikes`.
- **UI (popup).**
  - Preview, under the toggles: a button "HD" with `sparkles.rectangle.stack` or an
    existing icon (grep Views first), enabled when the selected strike has a plain,
    non-HD track; label "HD ✓" and disabled when it already is. Help text says what it does.
  - Actions header: "HD for all" (same icon), runs it for every strike with a plain track.
  - Row flag: a small "HD" capsule badge on rows whose saved track is HD. The sheet loads
    `fetchStrikeHighlights(videoID:)` and refreshes on `strikeHighlightRevision`.
  - All of it `lineLimit(1)` + `fixedSize`.

## Tests

`StrikeHighlightContourRulesTests`: capsule mask geometry and the past-the-joint
extension; boundary tracing of synthetic bitmaps (rectangle, L shape, two blobs keeps the
larger); resampling gives 48 points, clockwise, starting nearest the first joint;
the 15% / 95% and 60% rules; `sample` interpolates two contours and drops a contour when
one neighbour lacks it; old JSON without `contour` decodes; `drawable` keeps contours;
painter draws a polygon and no band when a contour is present (pixel probe in a bitmap
context). No test may need Vision or a video file.

## Not in this plan

HD by default, HD during scoring, contours for the defender or the impact point, syncing.
