# Express podcast generation: where the time goes and how to cut it

October 21, 2026. Review only; nothing below is implemented except the
truncation fix noted at the end. Measurements are from
`~/Documents/ClipBuilder/data/logs/app.log` on the Apple M4 Pro (12 cores),
Debug app, the 29:43 four-feed Zoom podcast, Compact quality, 9:16 1080p.

## Measured

One 69 s Q&A clip rendered alone with VIP focus (11:45:52 → 11:46:38, 45 s):

| Stage | Wall | What runs |
| --- | ---: | --- |
| Framing | 21 s | Two feed cut-outs (ffmpeg), two Center Stage tracking passes (84 and 468 Vision samples at 10 Hz), two `AVAssetExportSession` exports at 1080×1920, two scale/pad passes |
| Segment encodes + assembly | 10 s | Two segment encode passes (1080×1920), concat with audio re-encode |
| Silent gap | 9 s | `RenderEngine.extractClip`: an unlogged full re-encode of the 69 s file for the look LUT, brand PNGs, captions and name tags |
| Reel compositor | 4 s | Bumper (cache hit) + the clip re-encoded again, then a final overlay burn |

The 31-clip batch (12:46 →): clips 1–4 start together, then one new clip
every 20–30 s, each taking about 100 s under contention; about 11 minutes
for the batch. One clip is encoded at full resolution five times: tracker
export, scale/pad, segment pass, extractClip, compositor pass (plus the
overlay burn). Audio is re-encoded to AAC at every step. Every ffmpeg render
call decodes in software; hardware decode is used only by analysis passes.
Vision runs under a global permit of 1, so tracking never overlaps across
clips. Each render creates its own `CenterStageService`, so tracking inside
one clip serialises on that actor too.

Caches: the framing prepass and segment caches (`RenderSegmentCache`) hit
across runs when the cut document is identical, but the `extractClip`
output is never cached, and feed-region clips always re-track even when the
scene has a saved Center Stage path (the "saved framing" label is wrong for
them).

## Recommendations, in order of payoff

1. **Fold the per-clip `extractClip` re-encode into the segment pass**
   (saves one full encode + decode per clip, about 9 s of 45). The look LUT,
   brand PNGs, captions and name tags are plain filter inputs; the segment
   encode in `MultitrackRenderer.renderSegment` already burns fused overlays.
   Pass `lookEffect` and the clip overlays into the podcast document render
   and skip `extractClip` when the segment pass burned them. Log the step
   either way (today it is silent).
2. **Stop exporting the tracked feed as a file.** Run `cameraPath(source:)`
   (tracking only) on the cut-out feed and apply the resulting crop path in
   the segment ffmpeg pass (`sendcmd`/`crop` keyframes, or the existing
   `AreaFramer.staticFilter` path for still spans). Removes the
   `AVAssetExportSession` encode and the scale/pad encode per feed: two of
   the five passes. The framing cache then stores the path, which is tiny,
   not a 1080×1920 intermediate.
3. **Skip the feed cut-out encode.** Give the tracker the region directly
   (crop in the `AVAssetReader` output or Vision's region of interest) instead
   of writing a cropped feed file first. One fewer encode and decode per feed.
4. **Track once per feed per clip, at a lower rate.** Feeds of a video call
   barely move: `Tuning.conversation` samples at 10 Hz; 4 Hz is enough for a
   seated speaker and cuts Vision work by 60 %. Cache the per-feed path by
   (video, feed region, span) so the preview, the VIP B-roll scorer and the
   render share it, and honour the saved Center Stage path for feed clips.
5. **Raise the Vision permit from 1 to 2–3.** The Neural Engine handles
   concurrent face requests; with 1, four parallel clips queue on tracking.
   Measure with `CLIPBUILDER_FFMPEG_JOBS` fixed to isolate the effect.
6. **Hardware decode for render ffmpeg calls** (`-hwaccel videotoolbox`) on
   the 1080p intermediates. The September tests found no gain on the 2868-
   wide fight source; the podcast intermediates are the encoder's own
   output and decode cheaply either way, so measure before adopting.
7. **Do not re-encode audio in intermediate passes** (`-c:a copy` where the
   graph does not touch audio): small but free.
8. **Batch of separate videos**: the intro bumper and watermark overlay are
   identical for all 31 reels; the bumper already hits the segment cache, but
   the final overlay burn runs per reel. Burning the watermark into the
   bumper once and fusing the clip overlays into the segment pass (item 1)
   leaves the compositor with a stream-copy concat for most reels.

Expected: items 1–3 take the single-clip case from five full-resolution
encodes to two (segment pass and compositor), roughly 45 s → 20–25 s; items
4–5 are what make the 31-clip batch scale, since it is tracking- and
encoder-bound rather than CPU-bound.

## Truncation bug found during the review (fixed in the tree)

A podcast cut whose main track holds several pieces (the VIP feed changes
from `BuilderStore.compose`) was paired with its one extracted file by
`WizardEngine.preparedDocument` piece by piece: the first piece got the
file, the rest were dropped, so a 69 s clip rendered as 13.5 s
(`me-fala-uma-coisa-…-69s-2.mp4`, 13.499 s). Fix: the pieces share the cut's
`originKey` in `timelineDocument(from:podcastCuts:)` and `preparedDocument`
merges consecutive same-origin main-track clips into one placement of the
full duration. The same mismatch also defeated the compositor's
stream-copy shortcut (`isPrerenderedPassthrough`), so the fix removes one
re-encode per reel too. Test: `WizardPodcastCutAssemblyTests`.
