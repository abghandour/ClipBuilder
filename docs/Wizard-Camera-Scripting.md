# Wizard camera scripting: seeing frames, speakers, and custom paths

September 15, 2026. Why "crop it to whoever is talking" could fail, and what the Wizard's agent can do about framing now.

## The gap

The podcast pass knew two layouts, a single camera and two feeds side by side. A four-person video call is neither: it was classified as side by side, every speaker turn resolved to the left or right column, and the stored camera paths parked the crop on one column with two people in it. The agent then reported "Center Stage follows the active speaker" without having looked at a frame.

## What changed

**Grid layouts in the podcast pass.** `PodcastVisualAnalyzer.inferTiles` clusters the face positions seen in a few sampled frames into fixed feeds, turns the distinct columns and rows into cells, and calls three or more feeds (or two stacked) a `grid`. Each speaker turn is placed in the tile whose mouth moved during it (`PodcastVisualAnalyzer.tileMetrics`, `PodcastSpeakerTimelineResolver.resolveGrid`); the People pass's portraits name the tiles. The camera path for a grid crops the speaker's tile at the canvas aspect (`tileCrop`). Tiles persist on the video (`podcast_tiles_json`), the tile on each turn (`speaker_turns.tile`), and exchanges get a `podcast:grid` tag. Existing podcasts need a re-analysis to gain tiles.

**Speaker maps for interviews.** `PodcastAnalysisService.mapSpeakers` runs the voice separation, layout and tile detection, and turn resolution on any transcribed video; the analysis pipeline runs it for interview footage after transcription. Interviews therefore carry who speaks when and where they sit, like podcasts.

**The agent can look.** Three additions to the edit agent's tools:

- `sample_frames` returns JPEG frames of a project video at up to 12 source times as image content the model sees, plus for each frame the people and faces Vision found, as fractions of the full frame with a person key when the tiles or the roster know them, and the grid tile under the largest face. `crop` returns just that rectangle, so a planned camera rectangle can be checked. The run coordinator lifts `images` out of the tool's JSON into MCP image parts; the text keeps their count.
- `query kind speakers` (video) lists the turns with start, end, person, side, tile and confidence, and the layout with its tiles.
- `query kind camera` (clip) shows the path a clip renders with: its own, its scene's, or the file's analyzed scenes stitched.

**Scripted camera paths.** `set_clip_camera_path` puts an explicit path on a wide main clip in Full Screen: 2 to 2000 keyframes, each a crop rectangle in fractions of the source frame at t seconds from the clip's source start, strictly increasing. It outranks the scene's and the file's paths in `MultitrackRenderer.resolveClips`, survives save and load (`camera_path`), shows in the inspector with a Clear button, and an empty list clears it. `BuilderCommandValidation` refuses bad rectangles and times; the runner refuses paths past the clip's source span.

**The self-check.** The agent's rules now say how to frame a named subject: sample frames at speaker changes or every few seconds, choose the rectangle around the subject at the canvas aspect, set the path, then verify by sampling three to five keyframe times with `crop` set to that keyframe's rectangle, fix what fails, and say which times were checked. It must not claim a framing follows someone without having looked.

## Who is talking: the speaker tracker

September 16, 2026. The podcast pass could tell at most two voices apart, and its picture cue read mouth openings at two frames per turn, so in a four-way call the attribution was near random. A measurement harness on a 100-second excerpt of a real call showed both cues failing on their own (mouth motion decisive on half the turns; audio confidence 0.5). The tracker that replaced them works for any number of on-screen people:

- **Face slots.** The layout's tiles (`inferTiles` now divides the frame into a uniform grid by the number of face columns and rows, because call apps lay feeds out evenly).
- **Active-speaker border** (`VisualSpeechActivity.ringHues`, `highlightShares`). Call recordings draw a colored border around the speaker's tile. Each tile's four edge bands (20% of the cell inward from each edge, boundary included) are scanned per sampled frame for thin lines of saturated color; a tile's score for a hue is its second-best edge, so a neighbor sharing one boundary line never lights. The highlight hue is learned per recording as the strictly saturated hue that lights exactly one tile at a time and visits at least two tiles; it is then followed with a relaxed saturation test, because a thin border blends into a bright wall. Each tile's low-percentile baseline of the hue is subtracted (green walls, orange posters), and one-bin blips take their neighbors' value. On the excerpt this cue covered 395 of 400 quarter-second bins and matched every frame checked by eye.
- **Mouth motion** (`VisualSpeechActivity.measure`). Frames are decoded at 640 px through an asset reader and sampled at eight per second; per tile, the mean absolute luminance change of the mouth region of the last face box, minus the same for the eye region, so head and camera motion cancel. Normalized per tile by its own median.
- **Voices** (`SpeakerFeatures`, `SpeakerClustering`). MFCCs with deltas and pitch statistics over one-second windows of speech, k-means seeded farthest-first with as many voices as slots, merged when centers are within 1.3 per-dimension standard deviations. Voices map to slots by how their speech lines up with the highlight (or, without one, the mouths), and only a voice that prefers a slot beyond chance contributes. On this recording the voices stayed poorly separated, so the picture carries the decision; the audio remains a tie-breaker.
- **Fusion** (`SpeakerTracker.track`). Per quarter-second bin: highlight (weight 2) + mouth share (0.55) + voice preference (0.45); a Viterbi path with a switch cost of 0.3 over the speech bins; runs of a slot become turns with the tile, its person and a confidence from the score margin. `PodcastAnalysisService.resolveTurns` uses it whenever two or more face slots exist, for podcasts and for the interview speaker map, and falls back to the side-based resolver otherwise.

Cost: about 12 seconds per 100 seconds of video on this Mac (decode plus Vision every two seconds), so roughly four minutes for a 30-minute call, inside the analysis pass.

## Editing a custom path in the app

A wide main clip in Full Screen has one Framing control in the inspector: Static (the draggable 9:16 crop), Tracking (the analysis's camera), Custom (keyframes). The timeline block carries a "Tracking" or "Custom" badge and, for a custom path, a tick per keyframe along its top. A path set by a script or the Wizard is labelled "set by the Wizard" until the user touches it (`TimelineClip.cameraPathSource`).

The live preview draws the crop the render will show at the playhead for both Tracking and Custom (`BuilderTimelineModel.cameraRect(for:atTimeline:)`, memoized per clip). In Custom, the inspector shows the source frame at the playhead with the crop over it: drag it or click to move, zoom with the slider, step between keyframes, add one at the playhead, remove one, and switch "Cut to this keyframe" on or off. A drag at a time with no keyframe within a quarter second inserts one; otherwise the nearest keyframe moves (`CameraKeyframes.setRect`). "Make Editable" on a Tracking clip copies the tracked path onto the clip. A hard cut is stored as a hold duplicate one hundredth of a second before the keyframe (`CameraKeyframes.setCut`, hidden from the keyframe list), so scripts, the renderer and the editor agree. Changing the canvas rescales custom paths around their centers, keeping heights (`CameraKeyframes.rescaled`). Custom paths live on the timeline clip, not on the library scene.

## Tests

`SpeakerTrackerTests` and `VisualSpeechActivityTests` (border scoring on a synthetic frame, hue learning, highlight and mouth-driven turns, the smoothed path), `SpeakerFeaturesTests` (synthetic voices separate; spectrum peak), `CameraKeyframesTests` (cuts, merge-or-insert, removal, rescale, seeds), `BuilderTimelineModelTests.customFraming` (framing switches, editing at the playhead, canvas rescale), `PodcastAnalysisTests` (grid tiles, grid resolution and crop, persistence, speaker map without transcript), `BuilderScriptTests` (camera path op round trip, apply, clear, refusals; speakers query), `MultitrackRendererPlanningTests` (explicit path precedence), `FrameSamplerTests` (sampling, cropping, validation, tool gating), `MCPServerTests` (frames arrive as image content), `BuilderCommandCatalogTests` (schema parity).

## Limits

- A grid needs faces Vision can find in the five layout frames; feeds that hide faces for most of a call fall back to the old layouts.
- Voice separation is weak on mixed call audio (the excerpt's four voices collapsed toward one cluster), so recordings without an active-speaker border and without clear mouth motion attribute poorly; a trained speaker-embedding model would be the next step.
- The active-speaker border is learned per recording and needs to visit at least two tiles; a call where one person talks throughout has no border cue and falls back to mouth motion.
- `sample_frames` costs a model image per frame; the rules ask for sampling at speaker changes rather than densely.
- The live preview shows the crop rectangle at the playhead exactly, but as a still; "Preview 5 s" shows the motion between keyframes.
