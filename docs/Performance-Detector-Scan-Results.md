# Detector scan: concurrent hardware-decoded passes

September 15, 2026. Follow-up to the [improvement plan](Performance-Improvement-Plan.md) item on avoiding unnecessary detector passes, and to the [encode-budget measurement](Performance-Encode-Budget-Results.md).

## Problem

The cold detector bundle (`FFmpeg.detectors`) ran two sequential software-decoded passes over the whole recording: black/freeze detection, then scene-change detection through `sceneChangeTimestamps`, which also decoded the audio it never used. On the 140.5 s fight source that was 20.8 s in the earlier local-analysis baseline. The cost scales with recording length and the results are cached by content identity, so this is a cold and invalidated-cache cost.

## Stage-level experiments

Measured on the fight source with the machine otherwise idle, single runs, `/usr/bin/time`; scripts and stderr captures under `build/performance-baseline-runs/2026-09-15/stage-experiments/detectors/`. Every variant reported the same fifteen cut timestamps; a padded fixture with black and frozen runs reported identical black, freeze and cut events across all variants, including hardware decoding.

| Variant | Wall time | CPU (user) | Notes |
| --- | ---: | ---: | --- |
| A. Sequential software passes (previous) | 20.55 s | 143.7 s | 11.62 s black/freeze + 8.93 s scene |
| B. The two software passes concurrently | 17.81 s | 143.7 s | Compete for cores |
| C. One decode, split filter graph | 16.73 s | 78.7 s | Filters share a single graph thread |
| D. C with VideoToolbox decoding | 15.91 s | 30.2 s | Wall time bound by the filter thread |
| E. C with `-filter_complex_threads 2` | 20.52 s | 73.1 s | Worse; these filters do not slice-thread |
| G. Single hardware-decoded pass, black/freeze | 12.33 s | 23.6 s | Slower than software alone: one thread |
| G. Single hardware-decoded pass, scene | 13.22 s | 18.1 s | |
| **F. Both hardware-decoded passes concurrently** | **12.73 s** | **40.9 s** | **Chosen**: 38% less wall time, 72% less CPU than A |

The single-decode graph the plan proposed does save the decode, but with the decode nearly free in hardware the filters themselves are the bound, and one graph runs them in one thread. Two hardware-decoded processes keep each filter chain on its own thread and cost two cheap hardware decodes. H.264 decoding is normative, so hardware and software passes see the same frames; the padded fixture confirmed the events match.

## Implementation

`FFmpeg.detectors(of:duration:)` runs `detectorSignals` (black/freeze) and `sceneChangeTimestamps` concurrently with `async let`, each with `-hwaccel videotoolbox` before the input when `ffmpeg -hwaccels` lists it. A hardware-decode failure retries that pass in software; the older-build mpdecimate fallback is unchanged. The scene pass now passes `-an`, so it no longer decodes audio. Timeouts scale with the recording: five seconds per second of media, at least 300 s and at most 3,600 s, instead of the fixed 120 s and 300 s limits. Filters, thresholds and parsers are unchanged, so existing cached detector results remain valid and the ReelDetectorCache key version was not bumped.

`CLIPBUILDER_DETECTOR_MODE=legacy` restores the sequential software passes for same-binary measurement; the harness exposes it as `--detector-mode legacy`. Tests: `VideoDetectorsTests/paddedFixture` now checks that the hardware and software passes report the same black, frozen and cut events, and `parsersIgnoreEachOthersLines` checks the parsers against interleaved stderr.

## Reproduce

```sh
python3 scripts/performance_baseline.py build
python3 scripts/benchmark_detector_scan.py \
  --source '/absolute/path/to/fight.mp4' \
  --output build/performance-baseline-runs/detector-scan --pairs 3
```

## Results

Three alternating pairs of the local-only analysis scenario in one Release profiling binary, executable SHA-256 `4549b549d332bd229934ff83a3b17d2c10a09d1359084f3fadff89e3e6f1c9fc`, `--scope none`, fresh caches per run, on the 140.5 s fight source. Only `--detector-mode legacy` differs. All six runs recorded the identical detector bundle (15 cuts, no black or frozen runs on this source). Evidence: `build/performance-baseline-runs/2026-09-15/detector-scan/` (`runs.json`, `summary.json`, per-run `detectors.json`, logs and samples).

| Phase | Sequential software passes, median (range) | Concurrent hardware-decoded passes, median (range) | Observed result |
| --- | ---: | ---: | --- |
| Cold detector scan | 21.587 s (21.471–21.696) | 12.848 s (12.824–12.949) | **40.5% less time**, about 1.7× faster |
| Cold scan sampled CPU (core-seconds, 500 ms samples) | 119.6 (116.6–120.6) | 35.5 (34.9–36.0) | **70.3% less CPU** |
| Cold scan sampled peak RSS | 390 MiB (387–392) | 668 MiB (667–669) | **278 MiB higher (+71%)**: two processes plus decoder buffers, for 13 s |
| Warm read from the database | 0.000 s | 0.000 s | Unchanged |
| Cancellation phase, including intentional 1 s delay | 1.084 s (1.072–1.087) | 1.087 s (1.075–1.087) | Unchanged |

The CPU figure sums sampled process CPU percentages over the phase and is an approximation. The wall-time gain matches the stage experiment (12.73 s). For a 60-minute recording, at this source's resolution, the scan would drop from roughly nine minutes to about five and a half; that extrapolation was not measured.

## Limitations

- Measured on one H.264 source at 2868 × 1320 on an Apple Silicon Mac with a Homebrew ffmpeg that lists `videotoolbox`. Sources VideoToolbox cannot decode fall back to software per pass, which then behaves like variant B above: still concurrent, but with the previous CPU cost.
- The scan now holds two decoding permits instead of one while it runs, and its memory is higher for the duration of the scan.
- Cuts-only analysis still computes the full bundle on a cache miss; the bundle is cached and reused by export metadata, so that was left as is.

