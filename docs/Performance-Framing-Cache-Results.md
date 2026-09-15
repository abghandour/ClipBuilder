# Framing reuse and caption source timing

September 14, 2026. Follow-up to [framing profiling](Performance-Framing-Profile.md).

## Changes

Framing now preserves the original transcript source offset separately from the
seek offset into the intermediate video. Previously, resetting the intermediate
seek to zero also selected captions from the beginning of the original video.
Nonzero trims, speed changes, crop splits and successive framing passes retain
their original transcript coordinates. The segment cache version is now v5 so
previously cached incorrect captions cannot survive the correction.

Completed Center Stage and tracked-area intermediates can now be restored before
tracking/export runs. The `multitrack-framing-v1` identity includes the original
source fingerprint or upstream framing identity, trim, speed-adjusted duration,
camera path, area, tuning, render settings, encoder arguments and renderer version.
Timeline placement and captions do not invalidate framing. Existing memoized
source identity is retained; no full media hash is added per clip or frame.

Fresh intermediates are staged in render-owned scratch storage and published
only after successful rendering, with original-source revalidation. They share
the existing atomic cache publication, cancellation rollback and **2 GiB LRU
budget** with segments, assembly groups and finished videos. Failed or degraded
framing is excluded. Cache I/O failure falls back to fresh framing. Additional
artifacts can increase eviction pressure within that shared quota.

## Measurement method

The available fight source is `Du Plessis vs Strickland R5 - UFC Middleweight
Championship.MP4`, **140.544490 seconds (2:20.544)**, 2868 × 1320. The benchmark
uses forty framed two-second clips, captions, two fades, global text and an
overlay block at 1080 × 1920. This is the exact-preview renderer; normal export
publication and metadata recording are excluded from the paired timing.

Both modes contain the caption correction. Only `--disable-framing-cache`
differs, isolating framing reuse from the earlier caption bug. Finishing and
assembly reuse remain enabled. Five independent pairs alternate order in one
native arm64 Release executable, with coverage disabled, fresh application
caches per run and no competing builds, tests or benchmarks. The OS file cache
is not purged; background activity and thermal state are not fully controlled.
RSS samples cover the app and descendants every 500 ms, not exact allocations.

```sh
python3 scripts/performance_baseline.py build
python3 scripts/benchmark_framing_cache.py \
  --source '/absolute/path/to/wide-fight.mp4' \
  --output build/framing-cache-pairs --pairs 5
python3 scripts/validate_framing_cache.py --root build/framing-cache-pairs
```

The driver checks forty warm segment hits, a finishing hit, thirty-nine unchanged
segment hits after editing the first caption, expected framing hits/builds and
absence of fallbacks. Every warm output must be byte-identical to its cold output;
the caption edit must change the output. Executable changes abort the comparison.
By default, only each completed run's marked scratch cache is removed after its
inventory and metrics are saved. Outputs, logs, manifests and samples remain;
`--keep-caches` also retains caches.

## Paired results

All ten app runs completed and passed the driver assertions.

| Measurement | Framing cache disabled, median (range) | Framing cache enabled, median (range) |
| --- | --- | --- |
| Cold render | 35.984 s (35.785–36.532) | 35.961 s (35.773–36.570) |
| Unchanged render | 11.588 s (11.533–11.959) | **0.211 s (0.205–0.237)** |
| One caption edit | 23.357 s (23.175–23.587) | **11.814 s (11.806–11.876)** |
| Warm framing preparation | 11.379 s (11.307–11.738) | 0.028 s (0.026–0.029) |
| Edited framing preparation | 11.489 s (11.365–11.744) | 0.027 s (0.026–0.029) |
| Sampled peak app + child RSS per run | 1,224.6 MiB (1,193.0–1,244.6) | 1,232.1 MiB (1,192.8–1,243.9) |
| Retained scratch cache size, median | 243.6 MiB | 339.1 MiB |
| Cancellation phase, including intentional 1 s delay, median | 1.450 s | 1.102 s |

Unchanged rendering uses **98.2% less elapsed time**, approximately 54.8× faster
on this forty-framed-clip fixture. Caption edits use **49.4% less time**. Warm and
edited renders restore all forty framing intermediates with zero fresh framing
exports; the edit retains thirty-nine segment hits and rebuilds one segment.
All thirty completed outputs satisfy the byte-identity/edit-change checks.

Cold medians differ by only 0.06%; no cold improvement is established. Sampled
peak RSS is **7.6 MiB higher (+0.6%)**, with overlapping ranges. Cache storage is
**95.5 MiB higher (+39.2%)** for this fixture, within the unchanged shared 2 GiB
quota. The cancellation phase includes the deliberate one-second wait and can
reach different pipeline stages in each mode; it is not a general cancellation
responsiveness comparison. The full overlay pass still runs after a caption edit.

## Correctness coverage

Regression tests cover original transcript timing through trims, playback speeds,
crop splits and both framing passes; independent full-render media equivalence;
framing key invalidation; cancellation during a hit and a fresh prepass; static
area fallback exclusion; and source changes between renders and during assembly.
The latter refuses publication when the source fingerprint changes mid-render.
Existing shared-cache tests also cover LRU eviction, restored-copy ownership,
missing inputs and cancelled producers; the framing artifacts use that same
storage implementation and quota.

The final focused suite passed **30 tests / 70 executions**. The full suite passed
**853 tests, zero failures, one opt-in live Drive test skipped** (1,050 passing
executions including parameterized cases). Normal and profiling Release builds
passed. Test evidence is retained in `build/stability-validation/framing-cache-tests/`.

Full decoded comparison of the first pair's cold and edited outputs matched
**all 2,381 video frames and 3,450 float-PCM audio frames per output**, including
timestamps, durations, byte counts and hashes. Every compared output is
79.433008 seconds long. Warm outputs are byte-identical to cold in all ten runs.
At timeline three seconds, the retained inspected still now correctly shows
“Baseline caption 2.” Reports and decoded hashes are retained alongside the runs.

## Export-path verification

The initial normal Release attempt launched against the isolated scratch profile, but the
Mac's session was locked (`CGSSessionScreenIsLocked=Yes`), with no accessible
windows. No UI export was started. The app was closed through its Quit menu;
that attempt did **not** complete a normal-app UI export check. An attempted
accessibility-tree traversal while locked produced repeated application/menu
nodes and a main-thread stall sample dominated by accessibility requests. That
sample is retained; it does not establish a renderer hang or a hang-free UI.

The diagnostic Release runner then exercised the **production export path**
(`preview: false`) against a fresh isolated database with all forty clips framed.
Cold, repeated and caption-edited exports completed in 66.285 s, 2.395 s and
18.880 s respectively. These are single functional observations, **not paired
whole-app speedup measurements**. All three output files exist and have matching
generated-video and reel-trait rows at 1080 × 1920. Warm and edited exports
restore forty framing entries; the warm export also restores forty segments and
the finished video, and the edit retains thirty-nine segment hits. Warm output
is byte-identical to cold, and editing the caption changes it. Cancellation was
acknowledged during the additional preview cancellation phase.

Evidence is in `framing-cache-export-check/export-validation.json`, its scratch
database, outputs, phase logs and manifest under the same dated evidence root.
The normal-app scratch database retained its original six generated-output and
six trait rows; the UI attempt added no export. All task-owned apps exited.

### Unlocked normal-app follow-up

The remaining UI check completed on September 14, 2026 using the same validated
normal Release binary, SHA-256
`cccc063e494b125dcb0b49a45a5f7a9f1e27633ff1ddc291c977ba99994e81fc`.
The scratch timeline has forty clips and **one** Center Stage clip, using the
same 140.544490-second fight source. Both exports were started with the actual
**Render to Library** control and displayed completion.

| UI export | Elapsed time | Framing builds / hits | Segment hits | Finishing hits |
| --- | ---: | ---: | ---: | ---: |
| First export in the v5 cache | 37.739 s | 1 / 0 | 0 / 40 | 0 |
| Unchanged repeat | 0.727 s | 0 / 1 | 40 / 40 | 1 |

These are functional observations, not a new paired performance comparison.
Both 1080 × 1920 outputs are 79.433008 seconds long and byte-identical. The scratch
database grew from six to eight generated-video rows and from six to eight trait
rows, with each new output joined to its trait record. No new save-error or hang
entries appeared. The owned app quit normally. No application source changed,
so the existing full-suite and Release-build validation remains applicable.

Although the database was isolated, these two exports used the standard Default
output folder. Only those two verified task-created files were moved into the
scratch evidence directory, and only their scratch database paths were updated;
existing files and the user's database were left untouched. Future UI fixtures
should keep report JSON below a separate evidence subdirectory: `ProfileStore`
enumerates every top-level JSON file, and the tolerant profile decoder supplies
Default names and standard media paths when profile fields are missing.

Evidence is retained in `build/stability-validation/framing-cache-ui/`: bounded
accessibility dumps, `app.log`, `validation.json`, output probes and both videos.
The helper checks visited elements and limits traversal to accessible windows,
with node/depth/time bounds. The locked-session check is now resolved.

## Evidence and scope

Paired evidence is retained under ignored
`build/performance-baseline-runs/2026-09-14/paired-framing/`. The executable SHA-256
is `2a48fe386477d93c53ff432a0febb23801cb0144259ac21461cc749373eb800d`.

This fixture does not establish long-recording throughput, live Drive behavior,
UI latency percentiles, or a speedup for every framing mode. The area fallback
test verifies exclusion and caption timing; it is not a successful tracked-area
performance benchmark. Changes remain uncommitted.
