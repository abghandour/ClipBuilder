# Overlay fusion: spanning overlays burned into segments

September 15, 2026. Follow-up to the [cold-render experiments](Performance-Cold-Render-Experiments.md), which left one structural option for cold Builder renders: stop decoding and encoding the whole timeline a second time in the final overlay pass.

## Change

Timeline-spanning overlays (a title across the whole video, an overlay across a cut) used to be burned in a final pass over the assembled video: one more decode and encode of every frame, about 10 s of the 27 s cold render on the 40-clip fixture, and 5.6 s of it just evaluating the overlay graph. Overlays that fit inside one segment were already fused into that segment's encode, but only before the first transition.

Now every spanning overlay is burned into each segment it touches, on that segment's own clock: an overlay that began earlier keeps a negative start, so its entry animation is already over and the raster is simply opaque; one that ends later stays enabled to the segment's end. Spanning overlays follow the segment-local ones in the filter chain, so the final-pass stacking (spanning on top) is preserved. With nothing left to burn, there is no final pass; the assembled video is the output, and the whole-finishing cache now also covers an assembly without overlays, so an unchanged rerender still restores the finished video in one copy.

Fusion applies only when it is exact:

- Every join is a hard cut or an xfade that combines the two clips pixel by pixel in place (fade, dissolve, wipes, circle open/close, radial, smooth, diagonal, horizontal/vertical open/close, slices). Blending two clips that both carry the same overlay at the same moment yields that overlay, whether the blend is linear or a per-pixel selection. Transitions that move, scale, crop or dip the picture (slides, covers, reveals, zoom, circle crop, pixelize, the flash cuts) and action recipes keep the final pass.
- No overlay touches a gap or bumper segment; those are windowed only by the final pass.
- No entry or exit fade is half over at a cut: ffmpeg's `fade` cannot start before a segment's first frame, so such a plan keeps the final pass. Slides are expressions on time and continue correctly across a cut.

Fusion is all-or-nothing per render, so the finishing cache and finishing ranges are untouched where the final pass remains. `CLIPBUILDER_OVERLAY_FUSION=off` (harness `--overlay-fusion off`) keeps the final pass for same-binary measurement.

## Two behaviour changes worth knowing

- **Overlay clock.** The final pass evaluated overlay windows and animations on the assembled video's clock, which carries the source container's start offset (about 23 ms on the fixtures here) and shifted its own output timestamps by about 10 ms. Fused overlays share the segment clock that captions already use, so an overlay now switches on and animates in step with the captions on the same frame. Animated entries and exits therefore differ from the old output by that sub-frame phase; static overlays match frame for frame.
- **Crossfade placement.** The final pass placed overlays at their timeline time on the assembled clock, which is shorter than the timeline by every crossfade's overlap; an overlay after two half-second crossfades appeared one second later than its clip. Fused overlays stay with the segment they were placed on, matching the Builder timeline, and the placement no longer depends on whether a crossfade fell back to a hard cut.

## Tests

`MultitrackRendererPlanningTests/overlayFusion` covers the local clocks, ordering after local overlays, the gap and straddling-fade refusals and the transition allowlist. `MultitrackRenderTests/mixedOverlayPasses` shows the same fixture with the final pass (two segment encodes, an xfade and an overlay burn) and fused (no burn), and that a slide keeps the burn. `spanningOverlayFusionMatchesFinalPass` renders three hard-cut clips with two spanning overlays both ways and compares them frame for frame (identical timing and audio, per-frame SSIM at least 0.99, allowing the extra trailing frame the old pass appended), then checks the unchanged rerender restores the finished video whole. The finishing-range tests opt out of fusion so the range path stays covered.

## Reproduce

```sh
python3 scripts/performance_baseline.py build
python3 scripts/benchmark_overlay_fusion.py \
  --source '/absolute/path/to/fight.mp4' \
  --output build/performance-baseline-runs/overlay-fusion-pairs --pairs 5
```

## Results

Five alternating pairs in one Release profiling binary, executable SHA-256 `08a589a57dfc618d5d2093e76cb4680bc074cd851ea36bcd7a5805c32e2db644`, `--scope none`, fresh caches per run, the 40-clip, 80-second fixture with one Center Stage clip, a whole-video title and an overlay block at 1080 × 1920. Only `--overlay-fusion off` differs. Every fused run burned both overlays into the segments and ran no final pass and no finishing ranges. Evidence: `build/performance-baseline-runs/2026-09-15/overlay-fusion-pairs/`; the memory experiments behind the concurrency cap are under `stage-experiments/overlay-fusion/`.

| Phase | Final pass, median (range) | Fused, median (range) | Observed result |
| --- | ---: | ---: | --- |
| Cold render | 26.886 s (26.619–27.390) | 20.024 s (19.381–44.976) | **25.5% less time**; the 45 s maximum is the last pair, whose control was also the slowest, and its samples show the same three processes at lower CPU |
| Unchanged rerender | 0.166 s (0.154–0.181) | 0.155 s (0.154–0.207) | Unchanged whole-finishing hit |
| First caption edit | 13.378 s (13.295–14.098) | 1.999 s (1.973–2.862) | **85.1% less time**: one segment encode and assembly, no range creation |
| Second edit of the same caption | 2.886 s (2.837–3.064) | 1.989 s (1.958–3.327) | **31.1% less time** than finishing ranges |
| Cancellation phase, including intentional 1 s delay | 1.05–1.11 s | 1.08–1.18 s | Similar |

| Memory and storage | Final pass | Fused | Observed result |
| --- | ---: | ---: | --- |
| Cold render sampled peak RSS | 1,571 MiB (1,553–1,627) | 2,270 MiB (2,216–2,333) | **699 MiB higher (+44%)** during the segment phase |
| First-edit sampled peak RSS | 1,436 MiB | 605 MiB | Lower: no range creation |
| Retained cache | 310.3 MiB | 245.8 MiB | 64.5 MiB less: no range files |

Each fused spanning overlay adds its RGBA raster stream to every segment process: a two-second segment costs 380 MiB alone and 758 MiB with the fixture's two overlays. Single harness runs of the fused cold render at segment budgets 4, 3 and 2 took 19.7, 19.4 and 22.1 s with peaks of 2,965, 2,259 and 1,638 MiB, so fused renders cap segment concurrency at three: the full time gain at 700 MiB over the old peak rather than 1.4 GiB. Budget two would restore the old peak for a 17% instead of 26% cold gain; `CLIPBUILDER_FFMPEG_JOBS=2` selects it.

### Validation

Pair 1's cold and second-edit outputs were compared with the control's: identical decoded audio and audio packet timing, mean per-frame SSIM 0.998 with a minimum of 0.9932 on timestamp-paired frames, and 2,380 frames against the control's 2,381 because the old final pass appended one frame and shifted timestamps by 10 ms (see the behaviour notes above). The integration test compares a hard-cut fixture frame for frame.

## Limitations

- Renders with slides, covers, reveals, zoom, circle crop, pixelize, flash cuts, action recipes, bumpers, an overlay over a gap, or a fade straddling a cut keep the final pass and the finishing ranges; nothing changed for them.
- Peak memory during a cold render is higher by about 190 MiB per fused overlay per concurrent segment. Many simultaneous spanning overlays multiply that.
- Overlay timing now follows the timeline (and the caption clock) rather than the assembled clock; existing projects with overlays placed after crossfades will see them up to the accumulated crossfade overlap earlier than before, which is where the Builder timeline shows them.

