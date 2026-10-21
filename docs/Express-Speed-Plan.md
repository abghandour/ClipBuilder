# Express podcast generation: fewer passes per clip

Date: October 21, 2026. Status: phases 1–4 implemented, review corrections included,
Debug build green and 174 tests across the render, framing, cache, VIP and podcast
suites pass; live timing of the 69 s clip and 31-clip batch not yet measured. Phases
5–8 pending. Measurements and the ranked findings are in
docs/Performance-Express-Podcast-Review.md.

## Goal

Cut the number of full-resolution encodes per podcast clip from five to two,
stop re-tracking feeds that already have a path, let tracking overlap across
clips, and keep output identical by timing, audio and per-frame SSIM
(`compareDecoded` in `MultitrackRenderTests`). Target for one 69 s clip
rendered alone: 45 s → about 20–25 s; for a 31-clip batch: at least 2×.

## Where we stand

For one podcast clip, `WizardEngine.extractPlannedClip` (podcast branch,
around line 4163) renders the cut document with `MultitrackRenderer.render(
preview: true)` (captions stripped, name tags removed), then calls
`RenderEngine.extractClip(source: framed, overlays:, effect: lookEffect)`
which re-encodes the whole file to burn the look LUT, brand PNGs, caption
PNGs and name tag PNGs. Inside the first render, each feed-region clip goes
through `AreaFramer.frame(region:)`: an ffmpeg encode of the cut-out feed, a
`CenterStageService.reframeClip` tracking pass (AVAssetReader + Vision at
`Tuning.conversation` 10 Hz) ending in an `AVAssetExportSession` export at the
area size, then an ffmpeg scale/pad pass, then the segment encode pass in
`renderSegment`. The reel compositor then re-encodes the clip again when the
prerendered passthrough check fails. `MediaWorkScheduler` grants one Vision
permit app-wide. Feed-region clips ignore the scene's saved Center Stage
path (`MultitrackRenderer` ~line 989 applies it only to full-frame
`centerStage && wide` clips). The framing prepass and segment caches live in
`RenderSegmentCache`; `extractClip` output is never cached.

## Rules

- Output parity: every phase adds or extends a `MultitrackRenderTests` /
  `RenderEngineTests` case that renders the same fixture before and after
  (or against a stored reference) and compares timing, audio and SSIM ≥ 0.99.
  Hardware encodes are not byte-deterministic.
- Every encode/decode step logs one line with its purpose, so a future log
  explains the whole wall time ("Clip 3: extract folded into segment pass").
- No change to what the user sees in the Builder document (the editable
  timeline keeps its pieces, paths and looks).
- Measure before adopting the optional items (phases 6 and 7) with
  `CLIPBUILDER_FFMPEG_JOBS` pinned and the Timings lines.

## Phase 1: fold the extract pass into the segment pass

- `MultitrackRenderer.render(document:…)` gains `burnIns: [RenderEngine.ClipOverlay]`
  (document-time PNG overlays with optional windows) and honours
  `document.trackSettings[].effect` as today. `renderSegment` adds the
  burn-ins that intersect the segment to its filter graph the way fused
  spanning overlays are added (the overlay-fusion path), and the look filter
  (`EffectCatalog.filter`) in the same graph, before encoding. When the
  burn-ins or look are present the segment cache key includes their
  fingerprints (PNG file fingerprints, window, position, effect spec).
- `extractPlannedClip` podcast branch: pass `overlays` as `burnIns` and the
  look as a whole-frame `compositeEffect`, keep `preview: true` semantics,
  and skip `extractClip` for foldable documents. Muting maps the segment's
  duration-bounded silent stereo AAC source so joins retain their audio input.
  Log the completed extraction and any deferred finishing decode/encode.
- The reel compositor's passthrough (`isPrerenderedPassthrough`) must now
  hit for the plain clip: assert it in a test with a one-clip document plus
  bumper (duration match, since the truncation fix).
- Test: `MultitrackRenderTests.podcastExtractFoldedMatchesTwoPass` renders
  the fixture both ways (old `extractClip` route kept behind a test-only
  flag) and compares with `compareDecoded`.

## Phase 2: tracker without the export and without the scale/pad pass

- `CenterStageService.cameraPath(source:start:duration:region:…)`: a
  tracking-only entry that takes the feed region (fractions of the source),
  crops each decoded pixel buffer to it before Vision (CIImage crop or
  `CVPixelBuffer` region copy; Vision's `regionOfInterest` is acceptable for
  detection, but the body/face boxes must be mapped back to the region), and
  returns normalized keyframes relative to the full source frame. No
  `AVAssetExportSession`, no feed file.
- `AreaFramer` gains `pathFilter(keyframes:source:area:)`: an ffmpeg filter
  fragment that crops with piecewise-linear x/y/w/h expressions in `t`
  (keyframes at `Tuning.keyframeInterval`, plus the cut keyframes the recipe
  path already emits), then scales to the area box and pads to the canvas.
  The crop expressions use ffmpeg's `crop` with `w`/`h`/`x`/`y` as functions
  of `t`; verify with a 2-keyframe fixture that the frame at the midpoint is
  the interpolated crop (SSIM ≥ 0.99 against a static ffmpeg crop at the
  interpolated values; the `AVAssetExportSession` export of the same path
  scales differently and sits near 0.97 on the test pattern, so that
  comparison is a looser ≥ 0.95 window check).
- `MultitrackRenderer` framing prepass for region clips: run the
  tracking-only pass, cache the keyframes (JSON) in `RenderSegmentCache`
  under the existing `prepassKey`, and hand `renderSegment` the path filter
  instead of an intermediate file. Full-frame area clips with a saved path
  (`clip.cameraPath`) take the same filter route. The old export route stays
  for non-feed areas until phase 2 is validated, then is removed.
- When the area box equals the canvas (Full Screen), the scale/pad is a
  no-op and is omitted from the fragment.
- Static fallback (tracking bails): the face-detected window from the
  VIP framing work becomes a constant crop in the same fragment.
- Tests: `AreaFramerTests.pathFilterInterpolates`, framing prepass cache
  stores keyframes not files, `MultitrackRenderTests` parity for a two-feed
  podcast document (SSIM ≥ 0.99 against the export route).

## Phase 3: no feed cut-out file

Covered by phase 2's tracking-only entry (the region is cropped per buffer,
not pre-encoded). Remove `AreaFramer.frame(region:)`'s feed encode once
nothing calls it; keep the log line ("feed 45%×45% at (50%, 5%) tracked in
place").

## Phase 4: track once, slower, and reuse

- `Tuning.conversation.analysisInterval` 0.1 → 0.25 (4 Hz),
  `keyframeInterval` 0.3 stays. Add a parity test on the fixture: the 4 Hz
  path against the 10 Hz path differs by less than 2 % of the frame width at
  every keyframe.
- Feed path cache key: (source fingerprint, region, start, duration,
  tuning name, framing version). Shared by the render prepass, the preview
  compositor (`WizardPreviewFraming` can read a cached path to draw the
  exact crop at the preview time) and the VIP B-roll scorer's face boxes
  (`VIPExpression.measure` reads the cached face boxes when present instead
  of decoding again).
- Honour the scene's saved Center Stage path for feed clips when the saved
  path's camera preset matches and the region is the full frame; otherwise
  track. Fix the "saved framing" label in `extractPlannedClip` so it is
  printed only when a saved path is actually used.

### Implementation notes for phases 1–4 (October 21, 2026)

- `ExpressPodcastRenderer` applies extraction-only settings to a document copy;
  `RenderBurnIns` shares extract/segment animation clocks. Debug TaskLocal flags
  retain the two-pass extract and path-export references.
- ffmpeg evaluates crop width/height only at setup or on a command. `pathFilter`
  uses per-frame `sendcmd` expressions for those dimensions, and `t` expressions
  for x/y. Balanced ramp sums avoid the expression evaluator's recursion limit;
  segment graphs are written to scratch filter files to avoid argv limits.
  A full-screen crop still needs scaling to the output size; its pad is omitted.
- JSON feed records include face boxes and compact expression samples from the
  same decode. Face boxes alone cannot reproduce the VIP luminance-change score.
  Keys additionally include target aspect and fallback focus, which affect pixels.
- Tests added: `podcastExtractFoldedMatchesTwoPass` (static/animated overlays,
  passthrough with bumper), `podcastFoldedMute`, `podcastFeedPathsMatchExport`,
  `pathFilterInterpolates`, `longPathExpressions`, conversation 4 Hz/10 Hz
  detection-fixture parity, saved-path eligibility, and cache/preview/VIP reuse.
  AAC generations are compared with decoded RMS error < 0.01 plus duration
  checks; existing exact-audio comparisons remain unchanged.
- Validation so far: Swift syntax parsing, whitespace checks, and isolated
  ffmpeg crop-command probes. No Xcode build, Swift Testing suite, Vision run,
  SSIM measurement, or real-clip timing was run. Claude must validate the
  synthetic detection fixture against real seated-speaker footage as well.

### Review corrections (October 21, 2026)

- Muted segments retain 44.1 kHz stereo AAC; regression coverage decodes the
  silence, checks the stream metadata, and joins two muted clips with a fade.
- Saved paths must match every keyframe's crop aspect to the target cell and
  must not ignore an area focus. Full-frame focused cells select their nearest
  detected face, with separate cached paths and focused static fallbacks.
- Equal-time keyframes produce step terms; interpolation/slicing preserves the
  right-hand crop at a cut. Crop dimensions use decoded-frame iw/ih and W/H.
- Express grading follows document compositing and document text/images, before
  extraction burn-ins. Clip and track effects stay intact. Transitions or
  retained final overlays defer extraction to preserve the old ordering.
- Extraction windows the document to the planned duration before rendering.
- Segment/framing cache versions invalidate earlier incorrect outputs. The
  installed ffmpeg accepts `-/filter_complex` and sendcmd W/H. Conversation
  cadence now has an explicit tuning flag; VIP expression logging defaults off.
- Added/extended render, framer, Center Stage and segment-key regression tests.
  Only `swiftc -parse` and `git diff --check` ran for these corrections; ffmpeg
  capability probes passed. No new build, Swift Testing, Vision or SSIM run.
- Optional FeedPathCache folder-scan indexing is deferred; it needs an explicit
  invalidation policy for shared cache writes, eviction and external clearing.

## Phase 5: tracking overlaps across clips

- `MediaWorkScheduler.Budget.vision`: 1 → `min(3, max(2, cores / 4))`.
  The permit is held per Vision call, so tracking passes of different clips
  interleave. Keep the per-render `CenterStageService` actor.
- Measure with the Timings lines on the 31-clip batch at jobs = 4: expect
  the "Framing" portion per clip to fall and the clip cadence to rise.
  Record the numbers in docs/Performance-Express-Podcast-Review.md.

## Phase 6 (measure first): hardware decode for intermediates

- `FFmpeg.decodeArguments(hardware: true)` on render calls whose input is a
  1080×1920 H.264 intermediate (segment pass, compositor, overlay burn).
  Adopt only if the single-clip render is faster; the September result on
  the 2868-wide source was neutral.

## Phase 7: audio copy in intermediate passes

- Segment pass and compositor use `-c:a copy` when the graph has no audio
  filter and the input is AAC 44.1 kHz stereo; the final file keeps the
  encode args. Parity test on audio (`compareDecoded` audio compare).

## Phase 8: batch of separate reels

- Burn the watermark overlay into the cached bumper segment once per batch
  (key includes the watermark fingerprint), and with phase 1 the clip's
  overlays are already in its segment, so the final "Burning N overlays"
  pass runs only when a document-wide overlay remains; otherwise the
  compositor is a stream-copy concat. Log "Finishing: stream copy".

## Verification

- Debug build; tests listed per phase.
- Real run on the user's podcast with the log: one 69 s clip alone should
  show two encode passes (segment, compositor passthrough or concat) and a
  Timings line around 20–25 s; the 31-clip batch at least 2× faster. Compare
  one output against a pre-change render with `compareDecoded` (SSIM ≥
  0.99, same duration, audio match).
