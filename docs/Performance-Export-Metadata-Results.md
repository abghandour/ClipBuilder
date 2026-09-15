# Export metadata performance

September 14, 2026. This follow-up measures the normal export path after a
finishing-cache hit. Earlier renderer baselines used `preview: true`, which
excludes generated-video publication and reel-trait recording.

## Finding

The initial instrumented normal-export capture identified detector scans as the
largest warm-export stage. It reused the 40-clip timeline built from the available
**140.54449-second (2:20.544)** fight source. The warm export took 16.320 seconds
in this capture, including 13.783 seconds in black/freeze/cut detection. Trait
frame extraction took 0.163 seconds, Vision inspection 0.484 seconds, crop
sampling 0.026 seconds, loudness 0.230 seconds and transcript projection 0.005
seconds. These stage measurements explain this capture; they are not a direct
comparison against the previous 4.8-second UI observation on another run.

## Change

Generated-video trait recording now reuses completed detector scans through
`ReelDetectorCache`. It is bounded to **2 MiB and 256 entries**, uses atomic JSON
writes and least-recently-used eviction, and treats cache I/O failures as misses.
The key covers the full video SHA-256, duration, FFmpeg version output and an
explicit detector implementation version. Copies under a different output name
can reuse the scan; content changes force a new scan. Failed and cancelled scans
are not published, and files changed during extraction are not cached.

Frame inspection, crop/loudness analysis, caption/transcript-derived fields and
per-output database records still run for each export. The cache contains only
completed detector results. It does not defer metadata work or change video
encoding. Both Builder and Wizard final exports use the shared recording path.

## Reproduction

```sh
python3 scripts/performance_baseline.py build
python3 scripts/performance_baseline.py record --scenario export \
  --source '/path/to/fight.mp4' --local-only --scope none \
  --output build/performance-baseline-runs/export-check
python3 scripts/benchmark_export_metadata.py \
  --source '/path/to/completed-export.mp4' \
  --output build/performance-baseline-runs/metadata-pairs --pairs 5
```

The `metadata` scenario measures trait recording on fresh copies of a completed
export. Each run uses a fresh scratch database/cache and performs a cold and warm
pass. `--disable-reel-detector-cache` supplies the control in the same executable.
The paired script alternates order, records phase timings and sampled process
RSS, and rejects executable changes during the comparison. `TRAIT_STAGE` log
lines identify component timings. Metadata-only timings exclude the render,
output copy and generated-video insertion; they must not be presented as whole
application render times.

## Validation and measurements

Five alternating pairs (10 fresh app runs, 20 trait-recording operations) used
one native arm64 Release executable with coverage disabled. The input was the
completed export from the stage capture, copied under new filenames per phase.

| Measurement | Control | Detector cache |
| --- | ---: | ---: |
| Warm metadata median | 13.247 s | 0.969 s |
| Warm range | 11.298–13.424 s | 0.567–1.195 s |
| Cold metadata median | 13.186 s | 13.537 s |
| Cold range | 11.247–20.313 s | 12.522–22.501 s |
| Median sampled peak app + child RSS per cold/warm run | 372.8 MiB | 397.0 MiB |
| Warm detector-stage median | 12.340 s | 0.141 s |

Warm trait recording used **92.7% less wall time**. The cold median was **2.7%
higher**; no cold-speed or memory improvement is claimed. All **20 persisted
trait vectors matched exactly**, including fresh controls and cache hits. This
is a metadata-stage improvement, not a 92.7% reduction in whole-app render time.

Six cache tests cover full-content/runtime/duration/version invalidation, renamed
copies, corruption, failures/cancellation, changed sources, unwritable storage,
bounds and real-media cached/uncached equivalence. Caption/transcript changes
remain reflected even when detector results are reused. The cache tests and
existing trait golden tests passed; normal and profiling Release builds passed.

The initial full parallel suite was **not green**. Full runs had timing-related failures
in scripting and export-cancellation tests; all 42 tests in those suites passed
when grouped separately. A remaining broad run passed 804 tests, skipped the
live Drive integration, and failed three AI-service tests. In the isolated AI
suite, nine passed; `AIServiceTests.timeoutIsNotRetried` still failed because its
fixture's count file was absent after the one-second process timeout. The single
test also failed in isolation. Those initial runs did not establish a full-suite
pass. See the validation follow-up below for the subsequent diagnosis.

### Timeout-test validation follow-up

The unchanged timeout test subsequently passed alone, in five repeated AI-suite
runs, and in a full suite with 849 tests passed and one skipped. The historical
failure was intermittent; the exact reason the shell did not write its count
file was not reproduced. The test nevertheless had a timing dependency: the
one-second process deadline can expire before the shell executes its first
statement, so a file written by that child is not a reliable request counter.

`AIService` now accepts an instance-scoped process executor, defaulting to the
existing `ProcessRunner.run` call. The test counts invocations at that boundary
and covers both the real one-second process timeout and an injected timeout
before the script runs. Both require the timeout error, exactly one invocation,
and no retry log. The temporary directory is explicitly retained through the
request, and the lock-protected test log collector is explicitly nonisolated.
The production timeout and retry policy are unchanged.

The final focused run passed all 55 executions across five AI-suite repetitions.
The subsequent full suite passed **849 tests, zero failures, one live Drive
integration skipped** (1,044 passing executions including parameterized cases).
No separate builds or benchmarks ran alongside either validation run. Summaries
and logs are retained under ignored `build/stability-validation/ai-timeout-tests/`;
the final result bundles are `/private/tmp/clipbuilder-timeout-final-focused.xcresult`
and `/private/tmp/clipbuilder-timeout-final-full.xcresult`.

## Normal-app check

The native normal Release app completed two exports against the isolated scratch
profile. The first took 22.926 s; the repeated export took **1.256 s**, with
**0.554 s** between the finishing-cache-hit and Saved log entries. Both generated
outputs have persisted reel-trait rows, and the detector cache contains one
shared content entry. This is a functional check, not a paired whole-app speed
comparison with the earlier UI run. The task-owned app was closed afterward.

## Evidence

All captures remain local under ignored `build/performance-baseline-runs/2026-09-14/`.
The initial successful stage capture is `export-traits-before-02`. Paired results
are in `export-metadata-pairs/validated-summary.json`, with per-run manifests,
phase reports, RSS samples and trait JSON. The paired executable SHA-256 is
`351f52cac049a7bc40a12036553396664a8994a193512d6b4297809cd364bc35`.
Normal-app functional verification is retained under `build/stability-validation/`. The preceding
`export-traits-before` directory is a failed launch of an older binary and is not
measurement evidence.
