# Repeatable video performance baselines

The opt-in baseline build exercises production services in a fresh scratch database. Normal builds exclude `PerformanceBaseline.swift` and keep normal startup. It does not optimize the pipeline.

## Build and record

Requires Xcode with Instruments, an unlocked graphical macOS session, and the app's FFmpeg tools. The build defaults to `/Applications/Xcode-beta.app`; override `DEVELOPER_DIR` when needed. The dedicated Release build disables code coverage with `ENABLE_CODE_COVERAGE=NO` and `CLANG_ENABLE_CODE_COVERAGE=NO`.

```sh
python3 scripts/performance_baseline.py build
python3 scripts/performance_baseline.py record \
  --scenario render --source '/absolute/path/to/fight.mp4' \
  --output build/performance-baseline-runs/new-render-01
python3 scripts/performance_baseline.py record \
  --scenario playback --source '/absolute/path/to/fight.mp4' \
  --output build/performance-baseline-runs/new-playback-01
python3 scripts/performance_baseline.py record \
  --scenario analysis --source '/absolute/path/to/fight.mp4' \
  --settings '/absolute/path/to/app_settings.json' \
  --output build/performance-baseline-runs/new-analysis-01
python3 scripts/performance_baseline.py record \
  --scenario contention --source '/absolute/path/to/fight.mp4' \
  --scope none --output build/performance-baseline-runs/new-contention-01
```

Every output directory must be new. The script supplies a separate bundle identifier and data-folder argument, validates a scratch ownership marker, disables ordinary launch maintenance, and injects a database without opening a user profile or starting its folder watcher. Only AI and transition settings are copied. AI analysis uses the configured provider/account and can incur its usual usage. `--local-only` omits AI and explicitly produces a partial analysis baseline. `--provider` and `--model` override analysis routing. `--limit` sets an external process deadline (default 1,800 seconds).

`--scope none` runs the same Release workloads without Instruments, retaining phase logs, source/build metadata, and app/child RSS samples. Use matching capture scopes for before/after timing comparisons. Each manifest includes the executable SHA-256 so binaries remain distinguishable while the working tree changes. For render-only controls, `--disable-finishing-cache` bypasses the complete finishing cache and `--disable-assembly-cache` bypasses crossfade group reuse in the same binary. Keep the finishing cache enabled when measuring the additional benefit of assembly reuse after a caption edit. Alternate enabled/disabled runs to reduce run-order bias; each run still needs a fresh output directory. This mode does not produce a trace or signpost tables.

`--scope all` is the default and captures media-process CPU samples and app signposts. `--scope app` provides a focused CPU capture when system-wide symbolication fails: the script briefly suspends its own newly launched scratch process, attaches the recorder, and resumes it before the workloads. Child RSS is still sampled. On the tested beta Instruments version, this mode produced usable CPU stacks but no custom signpost intervals, so use the all-process capture for stage timing. Traces and exported tables can contain process environment and local paths; retain them locally in an ignored directory.

For the incremental-overlay experiment, `--capture-overlay-inputs` retains the real final-pass inputs and hard-cut assembly groups. This render-only diagnostic adds file copies to the measured app phases; use the separate stage benchmark described in [the prototype report](Performance-Incremental-Overlay-Prototype.md), not capture-phase timings, for comparisons.

## Workloads

| Scenario | Measured phases |
| --- | --- |
| Analysis | Cold full detector bundle, unchanged database-cache read, visual AI analysis with optional scene tracking, detector cancellation |
| Render | Same 40-clip timeline rendered cold, unchanged, and after editing one caption; then cancellation of a changed render |
| Playback | First five-second preview, cached preview restart, 20 seconds of playback, and cancellation at a different position |
| Contention | Wait for background detector/render overlap, probe under load, request a five-second preview at 30 seconds, cancel and drain background jobs plus preview prefetch |

The render fixture has forty two-second clips, synthetic captions, a global text overlay, an overlay block, two fades, and a stored moving crop on one wide clip. It uses preview rendering, so it does not establish full-quality export performance. Synthetic boundaries/captions make cache comparisons repeatable; they do not validate transcription or editorial quality. The analysis scenario calls the visual analysis service with scene tracking enabled; this is a combined analysis/framing workload, not a literal recording of every current Analyze-screen action.

The contention scenario uses local detectors and an independent 40-clip render as background work. It records time until the requested preview is installed, then cancels and drains the jobs. It is not a sustained playback or gesture-latency test, and its five-second window starts at 30 seconds rather than the playback scenario's Center Stage clip at zero.

During the playback window, drag and scrub the actual timeline for an interaction recording. Playback alone does not establish gesture latency. Record which interactions were performed. Do not compare an interaction trace with an unattended playback trace.

## Evidence and interpretation

Instrumented directories contain `baseline.trace` (Time Profiler plus Points of Interest), `trace-toc.xml`, `manifest.json`, `phases.json`, `app.log`, `recorder.log`, the scratch database/caches, and `process-samples.jsonl`. The render case retains the three completed videos in `outputs/` for visual comparison. Traces record all processes to include media subprocesses; keep these machine-local artifacts out of Git. The manifest records revision, dirty status, machine, OS, FFmpeg, source metadata, and cache definition.

`BaselinePhase` signposts delimit workload phases. Existing service signposts provide stage detail. Phase counters count **successful `FFmpeg.run` calls** and commands with an explicit non-copy `-c:v`. They exclude ffprobe, AVFoundation exports, direct `ProcessRunner` calls (including detector scans), and cancelled/failed commands, and therefore are not total decoder/encoder counts. Inspect export signposts and process samples alongside these counters. A completed phase report describes workload execution; inspect the app log separately for UI and shutdown errors.

The callback is task-local: counters follow the measured operation's inherited task context, not every command within its wall-clock interval. UI callbacks and prefetch tasks can escape that context or outlive a phase. In particular, zero playback counters do **not** establish zero background encoding. Use trace intervals and subprocess samples to assess playback work.

RSS is sampled every 500 ms for the app and its current descendants. Report the maximum simultaneous sum as sampled resident memory; shared pages can be counted more than once and short peaks can be missed. Time Profiler is sampling evidence, not an allocation census. Cancellation phase duration includes the intentional delay before requesting cancellation; the app log separately reports detector/render acknowledgement latency.

Cold means fresh application artifact caches; the operating-system file cache is not purged. Use the same source, settings, build, machine, foreground applications, and power/thermal conditions for comparisons. Run scenarios sequentially. Collect at least five independent runs before quoting medians or improvements. Add Hangs/Hitches or SwiftUI instruments and longer gesture sessions before reporting p95 responsiveness. Use available fight footage for the analysis baseline and document its exact duration from `manifest.json` → `sourceProbe.format.duration`. The accepted initial fixture is `Du Plessis vs Strickland R5 - UFC Middleweight Championship.MP4`, 140.54449 seconds (2 minutes, 20.544 seconds). A representative 30–60-minute action recording, rotated footage, fallback containers, podcast, and Drive download cases remain additional coverage for the broader plan; unavailable long footage does not block this baseline.

## Normal export metadata

`--scenario export` runs the renderer with normal publication and reel-trait recording,
which the existing `render` scenario omits through preview mode. `--scenario metadata`
accepts a completed export as `--source` and measures trait recording on two fresh
copies (cold and warm). `--disable-reel-detector-cache` controls detector reuse in
both scenarios without changing the executable. Stage logs use `TRAIT_STAGE`.

Use `scripts/benchmark_export_metadata.py --source /path/to/export.mp4 --output
build/metadata-pairs --pairs 5` for alternating metadata-only pairs. See
[export metadata results](Performance-Export-Metadata-Results.md) for scope and validation.

## Framing before cache lookup

Profiling builds log `FRAMING_PASS` (unique jobs, clip uses and elapsed time for
each Center Stage/area pass) and `FRAMING_PREPARATION` (both passes together).
These timers are compiled out of the normal app. They include grouping,
tracking, intermediate encoding and file handling, before segment cache lookup;
the initial source fingerprint loop is outside the measured framing interval.

`record --scenario render --framing-clips 40` enables Center Stage on all forty
fixture clips. The default remains one. Use `scripts/benchmark_framing.py
--source /path/to/wide-fight.mp4 --output build/framing-profile --repetitions 3`
to explore the two workloads in alternating order, using one profiling binary
and fresh application caches. These are different rendered compositions, so
their timings are workload profiles rather than an optimization comparison.
Three exploratory repetitions support reported ranges; use at least five per
mode for the subsequent enabled/disabled optimization comparison.
See [framing profile results](Performance-Framing-Profile.md) for the measured
ranges and the caption-offset defect found in the larger fixture.

The current renderer fixes that caption offset and enables framing reuse.
`benchmark_framing.py` explicitly disables framing reuse to continue measuring
the work before caching; its current caption-edit behavior differs from the old
buggy profiling binary. For a controlled optimization comparison, use
`scripts/benchmark_framing_cache.py --source /path/to/wide-fight.mp4
--output build/framing-cache-pairs --pairs 5`, then
`scripts/validate_framing_cache.py --root build/framing-cache-pairs`.
Both comparison modes include the caption correction; only
`--disable-framing-cache` differs. See [framing cache results](Performance-Framing-Cache-Results.md)
and the [complete performance progress table](Performance-Progress-Summary.md).
