# Framing before segment-cache lookup

September 14, 2026. Profiling confirms that repeated framing dominates warm
renders with many Center Stage clips. It also exposes an existing caption-offset
defect that should be fixed before adding framing-artifact reuse.

The subsequent [caption correction and framing cache](Performance-Framing-Cache-Results.md)
implement that follow-up. The measurements below describe the earlier binary
and retain the original defect as historical evidence.

## Method

Six fresh application runs: three with the existing one-framed-clip fixture and
three with Center Stage enabled on all forty clips, reversing workload order on
the second repetition. Each run renders cold, unchanged, after a caption edit,
and during cancellation. These are exploratory workload profiles; the ranges
below are not an enabled/disabled optimization comparison.

The source is the available Du Plessis–Strickland fight recording,
**140.544490 seconds (2:20.544), 2868 × 1320**. The timeline contains forty
two-second clips, captions, two fades, a title and an overlay block. It uses the
exact-preview renderer at 1080 × 1920, excluding normal output publication and
reel-trait recording. All retained cold outputs are 79.433008 seconds long.

One native arm64 Release profiling executable was used, with coverage disabled
and no concurrent builds, tests or other benchmarks. Application caches start
fresh; OS caches and thermal state are not controlled. Executable SHA-256:
`add2733ea307bf2b3bb710c204ff177954d7cc5b3cd9ce35195e16c10c38693a`.

`FRAMING_PREPARATION` measures grouping, tracking, intermediate encoding and
file handling before segment lookup. It excludes the preceding source-identity
loop. `FRAMING_PASS` separates Center Stage and tracked-area work; these captures
had no area jobs. The timers are compiled only with `PERFORMANCE_BASELINE`.

## Results

Ranges across three runs per workload:

| Workload and phase | Total render | Framing preparation | Segment cache hits |
| --- | ---: | ---: | ---: |
| One framed clip, cold | 71.880–87.963 s | 0.760–2.855 s | 0/40 |
| One framed clip, unchanged | 0.905–0.949 s | 0.621–0.651 s | 40/40 |
| One framed clip, caption edit | 22.873–29.308 s | 0.557–0.657 s | 39/40 |
| Forty framed clips, cold | 56.404–70.143 s | 11.386–13.567 s | 0/40 |
| Forty framed clips, unchanged | 11.860–12.973 s | 11.532–12.544 s | 40/40 |
| Forty framed clips, caption edit | 50.680–78.306 s | 11.479–12.235 s | 0/40 |

Every unchanged run hit the finishing cache, with no framing fallbacks.
Framing accounted for **67.2–68.7%** of unchanged render time with one framed
clip and **96.7–97.9%** with forty. All forty unique framing jobs still ran on
each unchanged forty-clip render. The zero FFmpeg video-encode counter on those
runs excludes AVFoundation framing exports.

The two workloads produce different compositions. Their cold times cannot be
interpreted as a benefit from enabling more framing. No new rendering speedup,
memory improvement, UI responsiveness or long-footage result is claimed.

## Caption defect and implementation order

After framing, `MultitrackRenderer` replaces the source with a temporary video
and resets `ResolvedClip.sourceStart` to zero. `renderSegment` subsequently uses
that same offset to query the original video's transcripts. Consequently, later
framed clips use captions from the beginning of the source.

The retained forty-clip output at timeline time 3 seconds displays **“Baseline
caption 1”**. Its second scene consumes source seconds 2–4 and should display
**“Baseline caption 2.”** The frame and scratch-database mapping are retained in
`caption-at-3s.png` and `caption-offset-evidence.json`. This also explains why
editing the first caption invalidates all forty framed segments in this fixture.

Recommended implementation order:

1. Preserve the original transcript source offset independently of the
   intermediate video's seek offset. Cover nonzero trims, speed changes, split
   clips and both framing passes. Verify the correct caption on a later framed
   clip and that an unrelated caption edit retains unaffected segment hits.
2. Reuse completed framing intermediates through the existing bounded artifact
   cache. Give them a separate key namespace covering source identity, trim,
   speed-adjusted duration, camera path/tuning, area geometry, output settings
   and framing implementation version. Preserve existing memoized source
   identity behavior. Publish only after successful rendering and source
   revalidation; exclude fallbacks, failures and cancellation.
3. Run at least five alternating cache-enabled/disabled repetitions in one
   Release binary. Verify decoded output equivalence, invalidation, cancellation
   and quota eviction, then check normal export behavior.

The caption correction and framing cache are not implemented in this profiling
change. The measured framing duration indicates the available work to eliminate;
it is not a measured cache speedup.

## Reproduction and validation

```sh
python3 scripts/performance_baseline.py build
python3 scripts/benchmark_framing.py \
  --source '/path/to/wide-fight.mp4' \
  --output build/framing-profile --repetitions 3
```

The profiling Release build and all six workload runs passed. All six unchanged
outputs are byte-identical to their respective cold outputs; every caption-edit
output differs. These checks establish cache consistency; the caption defect
above remains. Python syntax, invalid-option rejection and whitespace checks
passed. No new normal-app UI check or full unit-suite run was performed for
these compile-gated diagnostics.

Evidence remains under ignored
`build/performance-baseline-runs/2026-09-14/framing-profile/`: `runs.json`,
`summary.json`, `validation.json`, manifests, phase logs, process samples and
retained media. The build log is
`/private/tmp/clipbuilder-framing-profile-build.log`. Changes remain uncommitted.
