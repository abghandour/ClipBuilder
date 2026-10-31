# Builder framing parity with Express

Date: October 31, 2026. Status: implemented the same day, uncommitted.

## What the user asked for

"Make sure the timeline (UI Builder) has feature parity with the AI Wizard
Express in regards to framing, focus, etc. Make sure that they both have the
same controls."

## Where we stood

Express (and the full Wizard) offer one `Framing` request per reel through
`Views/Wizard/FramingRows.swift`: Framing subject (Auto, Original, Center
stage, VIP/Fighter focus, Speaker focus, Layout), Show (Everyone / VIPs only),
VIP picker, Layout and source roles, Pull back, Shot, Moves, Fit (Fill /
Blurred fill), Blur, Feather, Free window, Focus frame with reset, Zoom, and a
drag/resize focus-frame handle plus scroll/pinch zoom in the preview.
`FramingPlanner.resolve` turns the request into one `FramingPlan` per clip,
stored in `TimelineClip.framingPlan`, which the renderer honours.

The Builder's clip inspector exposed only Position (Track default / Top /
Center / Bottom), Framing (Static / Tracking / Custom keyframes) and Crop to
9:16, all on the legacy wide-clip fields. A Wizard-made clip kept its
`framingPlan`, but nothing in the Builder could read or change the choice.

## The model

- `TimelineClip.framingRequest: Framing?` (JSON `framing_request`, Optional
  so older documents decode). It is the request the inspector shows; the
  resolved `framingPlan` stays what the render uses.
- `BuilderFraming` (Services/Framing/BuilderFraming.swift, nonisolated) owns
  the pure rules: `apply(plan, wide:cropXFrac:storedPath:sceneStart:to:)`
  installs a plan on a clip the way `WizardOrdinaryTimeline.apply` does, and
  `mirrorFocusFrame(before:after:)` copies a dragged static window back into
  the request so the inspector's Zoom and Focus frame rows follow the preview.
- `BuilderTimelineModel.setFramingRequest(uid, framing, type:)` stores the
  request, builds a `FramingContext` from the clip's scene (or its whole file)
  and resolves it; `clearFramingRequest(uid)` returns the clip to the
  analysis defaults. Both go through `updateClip`, so they coalesce into one
  undo step per clip.

## The controls

- The inspector's Framing section hosts the same `FramingRows` view as
  Express for every full-screen main clip (not bumpers, cutaways or clips in
  a crop area), with the clip's video type, roster and canvas aspect, so the
  menu, captions and availability reasons match Express exactly. Layout is
  the one subject left out: in the Builder a layout is a crop block, not a
  clip setting.
- "Use Analysis" clears the request. While no request is set, the legacy
  Position / Static-Tracking-Custom / Crop rows stay, so keyframe editing is
  not lost.
- The Builder preview shows a static focus window (and a blurred fill) the
  way the render does; dragging or resizing the window in the preview edits
  the request's focus frame, and the Zoom slider moves the same window.
- Clips in a crop area keep their area window / tracking / keyframe controls.

## Verification

- `BuilderFramingTests`: apply rules (static clears wide and sets the free
  crop, center stage sets the region and slices the stored path), the model's
  set / clear round trip, focus-frame mirroring from a dragged crop.
- Debug `build-for-testing`; live check in the Builder inspector.
