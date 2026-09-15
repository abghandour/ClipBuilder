# Incremental overlay finishing prototype

September 14, 2026. Follow-up to [crossfade group reuse](Performance-Assembly-Cache-Results.md).

## Status and scope

This is an **opt-in experiment**, not a change to normal app exports. It is implemented in `scripts/incremental_overlay_prototype.py`, with a diagnostic input-capture flag compiled only into the Release profiling app. The normal renderer and its existing caches remain unchanged.

The prototype captures the real renderer's assembled video, overlay PNGs, exact final-pass command and pre-concatenation assembly groups. It groups complete assembly groups into ranges of roughly four seconds, keeps the original overlay animation clock, preserves variable-frame-rate gaps, encodes each range independently, then stream-copies the assembled audio once when joining the video ranges. It caches finished ranges under a separate versioned identity with full group/raster hashes, neighboring-group dependencies, absolute timing and encoding arguments. Staged entries publish only after the final mux succeeds; cancellation removes new entries. The prototype uses up to four FFmpeg workers and a separate 2 GiB LRU cache. Run one process per cache directory.

Range trimming still evaluates earlier frames through the original overlay graph. Consequently later edits may cost more than an edit near the beginning. Cold renders repeat this prefix work for every range. Unsupported captures without hard-cut groups, with one range, or outside the normalized 30 fps path retain the full pass. This is not a production eligibility guarantee for arbitrary recordings or graphs.

## Reproduce

```sh
python3 scripts/performance_baseline.py build
python3 scripts/performance_baseline.py record \
  --scenario render --source '/absolute/path/to/fight.mp4' \
  --scope none --local-only --capture-overlay-inputs \
  --output build/performance-baseline-runs/overlay-capture
python3 scripts/benchmark_incremental_overlay.py \
  --capture build/performance-baseline-runs/overlay-capture \
  --output build/performance-baseline-runs/overlay-pairs --pairs 5
```

Capture adds file copies to the app workload; do not quote those capture-phase timings as controls. The subsequent experiment compares the **finishing stage only** on those retained inputs. It does not re-run caption rendering, assembly, framing, app scheduling or the whole-finishing cache lookup. Its timings cannot be substituted for the application's previous 12.270 s end-to-end caption-edit result. The unchanged whole-finishing cache path was already about 0.67 s and is not the target of this experiment.

`--mode full` executes the captured production final-pass command. Each benchmark mode starts with a fresh range cache, renders cold, then renders the captured caption edit. Five pairs alternate order. The manifest records the prototype source SHA-256, capture-build identity and FFmpeg version. Sampled RSS covers the prototype Python process and descendants, not the app; samples are taken every 500 ms and are not exact peak allocations.

The accepted fight recording is `Du Plessis vs Strickland R5 - UFC Middleweight Championship.MP4`, **140.54449 s (2:20.544)**. The fixture remains the same forty clips, two fades, captions, Center Stage, global text and overlay block at 1080 × 1920.

## Correctness findings

The initial time-seek experiment lost 18 frames across range boundaries. Forcing a uniform frame rate then removed an existing one-frame timing gap near the second transition. A single-pass segment-muxer experiment preserved the whole output's timing after explicitly selecting VFR, but the hardware encoder placed some keyframes later than requested: the first cached range contained 132 frames rather than the planned 120. Reusing those ranges with independently rebuilt ranges shortened the edited output. None of these versions was adopted.

The retained approach selects on the original filter clock, resets timestamps only after selection, uses explicit VFR output, restores the original video offset at the final mux and applies a per-range output duration cap. The cap is necessary even after filter trimming because encoder/output-frame rounding can otherwise add a final frame.

Independent encoding changes encoder history and keyframes, so decoded video is not expected to be bit-identical to the full pass. Timing/audio comparison and per-frame SSIM are reported separately; SSIM alone is not approval of changed quality.

## Verification commands

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_incremental_overlay_prototype.py
CLIPBUILDER_OVERLAY_CAPTURE='/absolute/path/to/captured/phase' \
CLIPBUILDER_OVERLAY_CACHE='/absolute/path/to/populated/prototype/cache' \
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_incremental_overlay_prototype.py
python3 scripts/validate_overlay_prototype.py \
  --reference '/absolute/path/to/full-pass.mp4' \
  --candidate '/absolute/path/to/incremental.mp4' \
  --output '/absolute/path/to/validation.json'
```

Seven unit checks cover range planning, invalidation and clocks. Two opt-in integration checks inject a final mux failure and cancellation during a real FFmpeg encode; neither may publish new cache entries or an output, and children must drain. Validation compares every decoded frame/audio sample and packet presentation timestamp, then reports per-frame SSIM. Its successful exit certifies timing/audio checks, **not** identical encoded pixels or production readiness.

The Release profiling build and real-input capture completed. The prior 841-test application suite was not rerun because production services are unchanged; this task's Swift change is compiled only into the profiling harness.

## Results and decision

**Keep the prototype out of normal exports.** The edit benefit is substantial, but the cold-render and memory regressions make this version unsuitable as the default.

Five alternating pairs, with prototype source SHA-256 `2ff6df1a5cbdc8946cf2359a516b5aad2135ec8cb78f5f29207cb827ee10fe92` and capture executable SHA-256 `5550fdd3b3fab6fd31b60719f893dad80c0cb40ccccba92ef5b0801e5b54f31b`. All twenty finishing operations completed.

| Measurement | Full pass, median (range) | Incremental prototype, median (range) |
| --- | --- | --- |
| Cold finishing | 10.303 s (10.292–10.375) | 56.762 s (51.834–57.700) |
| Caption-edit finishing | 10.303 s (10.299–10.344) | 2.332 s (2.248–2.368) |
| Cold sampled peak RSS | 592 MiB (588–595) | 2,013 MiB (2,006–2,020) |
| Edited sampled peak RSS | 590 MiB (586–592) | 580 MiB (564–582) |

The early caption-edit finishing stage used **77.4% less elapsed time**, restoring 18 of 19 ranges and encoding one. Cold finishing was **5.51× slower**, with about **3.40×** the sampled peak RSS. These are stage-only comparisons, not new end-to-end application render times or UI responsiveness results. The timing runs do not cover edits near the end of the video, long recordings, other encoders or the excluded application paths.

The next implementation question is how to create reusable ranges during a single cold pass while respecting actual independently decodable boundaries. Requested keyframe times cannot be treated as proof of the resulting chunk boundaries. That work needs its own timing, audio and quality validation before the prototype is integrated into the app.

Final verification passed:

- **9 prototype tests passed**, including cancellation during a real encode and a failed final mux. No new cache entries or output survived either failure.
- Both final benchmark cold and caption-edit outputs retained **all 2,381 video frames**, matching frame/packet presentation timing, including the existing timing gap. All **3,450 decoded float-PCM audio frames** and audio packet timing matched the full-pass controls. Video decoding differed slightly: mean per-frame SSIM **0.998691**, minimum **0.997459**, in both comparisons.
- A separate late fade/slide fixture crossing range boundaries retained all **361 frames**, with matching timing/audio; mean SSIM **0.999230**, minimum **0.997832**. The additional final-frame cap was necessary for this case. Transition and animation comparison stills were inspected; no obvious placement or timing difference was visible in those samples. This is not an exhaustive subjective quality review.
- A warm prototype rerender restored **19/19 ranges** with zero range encodes; compressed video/audio packet data and timing matched its cold output. This is a cache-correctness check, not a new application warm-preview speedup.
- Release profiling build, real production-input capture, Python syntax and changed-file whitespace checks passed. No normal app rendering implementation was changed.

Validation reports are `overlay-prototype-pairs/render-cold-validation.json`, `render-caption-edit-validation.json`, `warm-validation.json` and `overlay-prototype-animations/validation-v7.json`, with retained frame hashes and SSIM logs.

The experiment and all trial/capture evidence remain local under ignored `build/performance-baseline-runs/2026-09-14/`: `overlay-prototype-capture/`, `overlay-prototype-pairs/`, `overlay-prototype-animations/`, and the rejected trial directories. No user media or library database was modified. Changes are uncommitted.

