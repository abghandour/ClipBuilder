# Framing evidence: shared detections and skipped samples

September 15, 2026. Follow-up to the [detector scan change](Performance-Detector-Scan-Results.md) and the [improvement plan](Performance-Improvement-Plan.md) item on sharing source evidence.

## Problem

Two passes detected the same people in the same frames. Portrait fit, run during analysis on wide footage, extracts three frames per scene at a 720-pixel edge and runs Vision's human-rectangle detector on each. The framing pass, which the pipeline runs later inside the same run-scoped `SampledFrameCache`, extracted the same three frames (the JPEGs were cached) and ran the same detector again. The framing pass also sampled every scene even with a moving camera and no `framed:` tags, where nothing reads the samples: `staticPath` needs them only for the static camera and `framedKeys` only when tagging people.

## Change

`SampledFrameCache.humanBoxes(url:at:maxDimension:)` detects people once per frame per run and caches the raw normalized rectangles alongside the JPEGs, bounded to 4,096 entries. `Analyzer.portraitFit` and `FramingService.sampleFrames` both read from it and keep their own coordinate conventions and `primaryPeopleBoxes` filtering, so their decisions are unchanged; the framing pass now decodes a JPEG only for frames that contain someone, since it needs the pixels solely for appearance signatures. `FramingService.detectFraming` skips sampling entirely when the camera is not static and `tagFramedPeople` is false, and logs how many scenes it skipped.

`CLIPBUILDER_FRAMING_MODE=legacy` (harness `--framing-mode legacy`) restores per-caller Vision requests and sampling for every scene, for same-binary measurement. Tests: `FramingEvidenceTests` checks one Vision request per sampled frame across callers, cache misses for a different sample size, cancellation, that a moving camera without tags performs no Vision work while the static camera and tagging still do, and that portrait fit's second call is served from the cache.

## Reproduce

```sh
python3 scripts/performance_baseline.py build
python3 scripts/benchmark_framing_evidence.py \
  --source '/absolute/path/to/fight.mp4' \
  --output build/performance-baseline-runs/framing-evidence --pairs 3
```

The local-only analysis scenario gained three phases over forty two-second fixture scenes, nested in one run-scoped frame cache as the pipeline nests them: `portrait-fit-local-only`, `framing-static-local-only` (static camera, tagging on: the app's defaults) and `framing-tracked-local-only` (moving camera, tagging off). Each phase logs the cumulative Vision request count, and the run retains every scene's stored path and tags after the static phase (`framing-static.json`) and after the tracked phase (`framing-tracked.json`); the benchmark requires both to be identical across all runs, keyed by scene start time.

## Results

Three alternating pairs in one Release profiling binary, executable SHA-256 `318bcb4c807ee03843fd594e60dc032d8dd5ff2dc25d9d9739cffb574af85f47`, `--scope none`, fresh caches per run, forty two-second scenes over the 140.5 s fight source. Only `--framing-mode legacy` differs. Every run's static paths, `framed:` tags and tracked paths were identical when keyed by scene start time. Evidence: `build/performance-baseline-runs/2026-09-15/framing-evidence/` (`runs.json`, `summary.json`, per-run `framing-static.json`, `framing-tracked.json`, logs and samples).

| Phase | Per-caller Vision (previous), median (range) | Shared evidence, median (range) | Vision requests per run | Observed result |
| --- | ---: | ---: | ---: | --- |
| Portrait fit, 40 scenes | 1.938 s (1.859–1.960) | 1.862 s (1.844–1.927) | 120 → 120 | Unchanged: this is where the detections are made |
| Static camera with `framed:` tags (app defaults) | 0.566 s (0.563–0.569) | 0.093 s (0.092–0.093) | 120 → 0 | **83.5% less time**; every detection served from the run's cache |
| Moving camera without tags | 5.604 s (5.563–5.964) | 4.857 s (4.779–5.445) | 120 → 0 | **13.3% less time**; sampling skipped, tracking unchanged |
| Sampled CPU across the three phases (core-seconds) | 2.8 | 1.8 | | Approximate, 500 ms samples |

Peak sampled RSS stayed between 173 and 193 MiB in every phase of every run. On this fixture the absolute saving is about 1.2 s per analysis; it grows with the number of scenes and with source resolution, since each avoided request is a 720-pixel frame extraction plus a Vision pass.

One finding from the comparison itself: `saveAnalysis` inserts scenes in an order that varies per process (dictionary iteration), so scene ids do not identify the same scene across runs. The benchmark keys its comparison by start time; earlier attempts keyed by id reported spurious differences.

## Limitations

- Portrait fit runs during analysis and the framing pass later in the same pipeline run; the cache lives only for that run. A framing pass started on its own (Re-run framing, or after relaunch) still detects people itself, as before.
- The moving-camera saving applies only when `framed:` tagging is off; the app default keeps tagging on, where the static-camera row applies instead.
- Measured on one source; scenes with no people still cost a frame extraction and a detection in both modes.

