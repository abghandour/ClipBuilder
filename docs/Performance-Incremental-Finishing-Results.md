# Finishing ranges on the edit path

September 15, 2026. Follow-up to the [incremental overlay prototype](Performance-Incremental-Overlay-Prototype.md), which was kept out of normal exports because its cold finishing pass was 5.51× slower and used 3.40× the memory.

## Decision and scope

The final overlay pass now runs as cached **ranges** on the edit path only. A cold render keeps the single full pass exactly as before. Ranges are created the first time a render reuses at least one cached segment, which is the signature of a re-render after an edit; from then on an edit re-encodes only the ranges whose assembly groups changed. The renderer's `incrementalFinishing` policy defaults to `editsOnly`; `off` restores the previous behaviour and `always` creates ranges on cold renders too (used by tests and available to the harness).

Eligibility is the same as the whole-finishing cache: at least one timeline-spanning overlay, no sound track, bumpers or action recipe transitions, every segment reusable, and no hard-cut fallback during assembly. In addition, the assembled video must carry the renderer's normalized 30 fps clock and plan to at least two ranges. Anything else, and any range encode or join failure, takes the existing full pass; a failure is logged as `Finishing ranges failed` and never costs the render its overlays.

## Why the prototype's cold cost disappeared

The prototype trimmed each range after evaluating the overlay graph from time zero, so nineteen ranges evaluated the prefix nineteen times. Two stage-level experiments on the retained production capture (`build/performance-baseline-runs/2026-09-14/overlay-prototype-capture`, 40 clips, 79.423 s output, 38 hard-cut groups) settled the design. Scripts and validation reports are under `build/performance-baseline-runs/2026-09-15/stage-experiments/`.

**Input seeking replaces prefix evaluation.** With `-ss` before the assembled video *and* before every looped raster, plus `-copyts`, the overlay clock stays absolute, so enable windows, fades and slides evaluate as in the full pass. The range output was pixel-identical and timing-identical to the prefix-trimmed version:

| Single range rebuilt | Prefix trim (prototype) | Input seek |
| --- | ---: | ---: |
| Range 9 of 10 (75.4–79.4 s) | 5.951 s | **0.780 s** |
| Range 5 of 10 (43.4–51.4 s) | 4.123 s | **1.257 s** |

Evaluating the whole graph without encoding takes 5.647 s of the 10.289 s full pass, which is why late edits were so expensive before.

**Creating every range costs about one full pass.** Encoding all ranges from seeked processes, then joining them by stream copy:

| All ranges missing (single Python driver, captured inputs) | Time | Largest single process |
| --- | ---: | ---: |
| Full pass (control) | 10.289 s | 565 MiB |
| 19 ranges, 4 workers | 11.968 s | 556 MiB |
| 19 ranges, 3 workers | 11.702 s | 555 MiB |
| 19 ranges, 2 workers | 12.224 s | 557 MiB |
| 10 ranges, 4 workers | 11.413 s | 552 MiB |

A single-process alternative (one graph evaluation split into trimmed branches with one encoder per range) matched the full pass in time (10.798 s for 19 ranges) but held every encoder session open, adding about 45 MiB per range in one process. Per-range processes were chosen because their memory is bounded by the worker count rather than the range count. The shared hardware encoder gains little beyond two workers, so the renderer uses two; the earlier one-pair smoke run with four workers peaked at 2,524 MiB of sampled app-plus-child RSS during range creation, against 1,567 MiB for the control.

Both joined outputs kept all 2,381 frames with identical frame and packet presentation timing and identical decoded audio against the captured full pass, mean per-frame SSIM 0.998691 and minimum 0.997459, the same as the prototype: independently encoded ranges are not expected to be bit-identical to one continuous encode.

## Implementation

`RenderFinishingRanges` plans ranges from the hard-cut assembly groups (a single segment or a crossfaded run), cutting only between groups, at least four seconds each and longer for long outputs (one twenty-fourth of the duration), the last range taking the rest. Boundaries are placed on whole frames of the assembled clock, including its start offset; the last range's trim keeps the final frame but stops before the extra frame that output rounding could add, and every range carries its own output cap and explicit VFR, as the prototype found necessary.

`RenderEngine.concatenate` now reports the groups it is about to hard-cut together, while their intermediates still exist; the renderer probes their durations and identifies each group by its segment digests, transitions and crossfade duration. A range key covers its groups plus one neighbor on each side (frame resampling around a hard cut can reach into the adjacent group), the overlay rasters and windows, render settings, encoder arguments and the segment renderer version, under the `multitrack-finishing-range-v1` namespace. Segment digests are computed once and shared with the whole-finishing key.

Ranges are restored from the shared 2 GiB segment cache or encoded by a seeked FFmpeg process (two at a time), then joined with the assembled audio by stream copy. Range files are staged in the render scratch and published only when the whole render succeeds, through the same rollback-on-cancellation path as segments; the whole-finishing artifact is still published, so an unchanged rerender keeps its 0.2–0.7 s path. The log line `Finishing ranges: hits=N encodes=M` reports each pass.

Tests: `RenderFinishingRangeTests` covers planning, clock placement, key dependencies and the exact FFmpeg arguments; `MultitrackRenderTests/finishingRangesOnEditPath` renders a three-group fixture cold (full pass, no ranges), after a first edit (two segment hits, ranges created), after a second edit of the same group (one range restored, one encoded) and after a title change (every range invalidated), and checks frame count, frame timing and decoded audio against a full-pass render; it also covers the `always` policy and the whole-finishing hit after it.

## Reproduce

```sh
python3 scripts/performance_baseline.py build
python3 scripts/benchmark_incremental_finishing.py \
  --source '/absolute/path/to/fight.mp4' \
  --output build/performance-baseline-runs/finishing-ranges-pairs --pairs 5
```

The harness now renders a fourth phase, `render-second-edit`, which changes the same caption again: the steady state after ranges exist. Phase log lines carry an epoch so the benchmark reports sampled peak app-plus-child RSS per phase.

## Results

Five alternating pairs in one Release profiling binary, executable SHA-256 `421fff174ab86a548bc4c541e6d610e78d9bb5772989092bd70f3cf7cb994c85`, `--scope none`, fresh caches per run, the usual 40-clip, 80-second fixture with one Center Stage clip at 1080 × 1920. Only the `--incremental-finishing` switch differs (`off` for the control, `editsOnly` for ranges). Every run completed; no fallback or range failure was logged. Evidence: `build/performance-baseline-runs/2026-09-15/finishing-ranges-pairs/` (`runs.json`, `summary.json`, per-run logs, outputs and cache inventories).

| Phase | Full pass, median (range) | Ranges on the edit path, median (range) | Observed result |
| --- | ---: | ---: | --- |
| Cold render | 27.292 s (26.798–29.126) | 26.944 s (26.149–27.600) | 1.3% lower median; the code path is unchanged, so this is noise |
| Unchanged rerender | 0.160 s (0.151–0.216) | 0.161 s (0.148–0.186) | Unchanged whole-finishing hit |
| First caption edit (creates 19 ranges) | 11.695 s (11.666–11.890) | 13.434 s (13.309–13.603) | **14.9% higher median**: the one-time range creation |
| Second edit of the same caption (18 restored, 1 encoded) | 11.710 s (11.677–12.091) | 2.941 s (2.925–3.174) | **74.9% less time**, about 4.0× faster |
| Cancellation phase, including intentional 1 s delay | 1.082 s (1.075–1.135) | 1.074 s (1.067–1.270) | Similar |

Sampled peak app-plus-child RSS inside each phase (500 ms samples; the unchanged rerender is shorter than the sampling interval):

| Phase | Full pass | Ranges | Observed result |
| --- | ---: | ---: | --- |
| Cold render | 1,528 MiB (1,502–1,599) | 1,572 MiB (1,520–1,643) | Overlapping ranges; unchanged code path |
| First caption edit | 825 MiB (797–886) | 1,400 MiB (1,391–1,446) | **575 MiB higher** while two range processes run; below the cold render's peak |
| Second edit | 838 MiB (794–905) | 840 MiB (663–895) | Unchanged |
| Retained cache after the run | 290.0 MiB | 310.3 MiB | **20.3 MiB more disk (+7.0%)** for 19 range files |

The first-edit phase runs 20 successful video encodes (one segment plus nineteen ranges) instead of two; the second edit runs two (one segment plus one range) in both modes, but the ranges mode's second encode covers four seconds rather than the whole 79 s output. Segment hits were 39 in every edit phase, so the caption edit invalidated only its own segment, as before.

### Validation

Pair 1's edited outputs were compared against the control's outputs for the same edits with `scripts/validate_overlay_prototype.py`: both kept **all 2,381 video frames** with identical frame and packet presentation timing and identical decoded audio (`validation-pair01-render-caption-edit.json`, `validation-pair01-render-second-edit.json`). Mean per-frame SSIM was 0.998691 (minimum 0.997459) for the first edit and 0.998689 (minimum 0.997459) for the second, matching the prototype. Decoded pixels differ because ranges are separate encodes; SSIM describes that difference and is not approval of it. The one-pair smoke run before the worker cap was validated the same way.

The Swift suite result is recorded in [the progress summary](Performance-Progress-Summary.md).

## Limitations

- The gain is for the second and later edits of a timeline. The first edit after a cold render pays about 1.7 s and 575 MiB more on this fixture to create the ranges. Setting the policy to `always` would move that cost to the cold render, which this task deliberately left unchanged.
- An edit that changes a group's length shifts every later boundary, so ranges after it are rebuilt. Raster changes (title text, fonts, overlay timing) rebuild every range.
- Ranges apply only where the whole-finishing cache applies: no sound track, bumpers or recipe transitions, and at least two ranges. A five-second exact preview usually plans one range and keeps the full pass.
- Only this fixture, this machine, hardware H.264 and 1080 × 1920 were measured. Long recordings use longer ranges (one twenty-fourth of the output), which were not benchmarked. The 2 GiB cache quota is shared with segments and the whole-finishing artifact, so heavy editing increases eviction pressure.

