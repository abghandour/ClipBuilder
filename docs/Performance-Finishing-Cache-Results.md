# Finishing cache and post-scheduler measurements

September 14, 2026. Follow-up to [the initial baseline](Performance-Baseline-Results.md) and [the scheduler changes](Performance-Scheduling-Results.md).

The next implementation and measurements are documented in [crossfade group reuse after caption edits](Performance-Assembly-Cache-Results.md).

## Scope and controls

The accepted fight source is `Du Plessis vs Strickland R5 - UFC Middleweight Championship.MP4`: **140.54449 seconds (2:20.544)**. All timing runs use the same 40-clip, 80-second nominal timeline, captions, two fades, global text and an overlay block, plus one Center Stage clip. These are exact-preview renders at 1080 × 1920.

The post-scheduler instrumented control completed in 27.026 s cold, 13.206 s warm, and 13.618 s after a caption edit. The original warm result was 13.205 s. This demonstrates no render-throughput gain from the scheduling change in this fixture; its purpose is admission, prioritization, and cancellation under load.

Beta Instruments again reported overlapping simulator libraries and spent much longer saving than executing the workload. The instrumented render and local-analysis controls are retained. Repeated comparisons use `--scope none`, with phase logs and 500 ms app/child RSS sampling. Builds and tests are kept outside timed workloads. Each run has fresh application caches; the OS file cache is not purged. Executable SHA-256 values distinguish the binaries while uncommitted work is in progress. Do not pool instrumented and uninstrumented timing samples.

Local analysis measures detector scans, the thumbnail grid, and tracking over the first 60 seconds. It omits remote AI requests; it is not a repeat of the original full AI analysis phase. Contention waits until a detector scan and independent render overlap, probes the source, requests a five-second preview at 30 seconds, then cancels and drains background work and prefetch. This measures preview installation and cancellation, not sustained playback or p95 gesture latency.

## Implementation

The new finishing artifact reuses a completed assembly-and-overlay result when all segment artifacts are reusable. Eligibility requires a remaining full-timeline overlay and excludes sound-track blocks, bumpers, and action recipe transitions. Those cases retain their existing pipeline.

The key streams every byte of the rendered segment files and overlay PNGs, includes their ordering, overlay visibility/animation windows, transition names and the captured crossfade duration, render settings, encoder arguments, and the segment renderer version. It uses the `multitrack-finishing-v1` namespace. Scratch names and overlay UUIDs do not affect identity. Hashing runs off the main actor with cancellation checks and 1 MiB reads.

The key uses cached segment inputs rather than newly assembled output bytes. The retained original cold/warm outputs differed in two bytes despite otherwise identical file content, so rerunning an encode cannot be assumed to reproduce identical bytes. The actual cached segment files remain stable on a segment hit.

Only successful complete renders publish the finishing artifact, using the existing staged cache publication and 2 GiB LRU budget. Completed videos share that quota with segments, so frequent edits can increase eviction pressure. Source fingerprints are checked before publication. Caption-degraded or otherwise uncacheable segments are ineligible; an assembly hard-cut fallback clears the candidate key. Overlay failures and cancellation do not publish. The existing fade/filter graph is unchanged, and the assembly uses the same transition-duration snapshot that appears in its key.

A hit still performs framing preparation, segment lookups, and input hashing, then restores the completed video. It skips assembly and the remaining overlay pass. It does not eliminate Center Stage prepasses. A caption/title/trim/timing change invalidates the relevant segment or finishing key; this prototype does not make single-edit finishing incremental.

## Results and validation

### Primary comparison: alternating controls in one Release binary

Five independent runs per mode, `--scope none`, reversing enabled/disabled order on alternate pairs. All use executable SHA-256 `c3001b28278960f6a14df1f920aeb08cb36339087f7dbf1135e7b4da197ff3a0`. Only the render-harness `--disable-finishing-cache` switch differs.

| Phase | Cache disabled, median (range) | Cache enabled, median (range) |
| --- | --- | --- |
| Cold render | 26.845 s (25.893–27.440) | 26.605 s (26.373–27.322) |
| Unchanged rerender | 13.131 s (13.092–13.174) | **0.670 s (0.653–0.686)** |
| One caption edit | 13.576 s (13.553–13.592) | 13.609 s (13.585–13.662) |
| Cancellation phase, including intentional 1 s delay | 1.059 s (1.030–1.067) | 1.051 s (1.039–1.060) |
| Sampled peak app + child RSS | 1,608 MiB (1,526–1,637) | 1,609 MiB (1,544–1,619) |

The clear result is **94.9% less elapsed time for the unchanged rerender**, approximately 19.6× faster on this fixture. The warm finishing pass drops from three successful ffmpeg video encodes to zero; Center Stage work still occurs earlier and is not included in that ffmpeg counter. Cold and single-edit timings are similar, with a small additional cost for the edited case. These measurements do not establish a cold-render speedup or a memory improvement.

The initial sequential batches showed slower cold/edited runs and preview installation after the prototype (warm rerender still improved). The alternating same-binary controls did not reproduce that larger render penalty. Background processes and thermal state were not controlled, so the sequential difference cannot be assigned to the cache alone. This is why the alternating controls above are the primary comparison.

### Scheduler and local-analysis checks

Five post-scheduler runs per workload, with the accepted short fight source:

| Measurement | Median | Range |
| --- | --- | --- |
| Cold detector bundle | 20.790 s | 20.537–22.379 s |
| Cached detector read | 0.162 ms | 0.138–0.188 ms |
| Thumbnail grid | 0.394 s | 0.387–0.412 s |
| First 60 s of tracking | 3.229 s | 3.086–3.678 s |
| Probe during background analysis/render | 28.9 ms | 27.8–32.7 ms |
| Requested preview installation under load | 5.001 s | 4.779–5.029 s |
| Cancel and drain background work/prefetch | 0.387 s | 0.352–0.499 s |

The retained instrumented render observed at most four simultaneous ffmpeg/AVFoundation encoding intervals, matching the configured budget. Warm `OverlayBurn` was 10.333 s and assembly 2.162 s. Identical signpost intervals from duplicate Points of Interest tables were deduplicated before counting.

The first cache-enabled sequential contention batch had a 5.477 s median preview installation; a later validation in the final control binary took 4.491 s, with a 28.1 ms probe and 0.486 s cancellation drain. Both background tasks explicitly returned cancellation errors. These are not paired preview comparisons and do not demonstrate a preview-under-load speedup or establish p95 responsiveness.

### Correctness and build checks

- Full `scripts/test.sh`: **840 tests passed, 0 failed, 1 skipped** (the opt-in Google Drive round trip). Result bundle: `/private/tmp/clipbuilder-finishing-full.xcresult`.
- New tests cover scratch/overlay identity stability, complete segment/raster hashing, render-input invalidation, byte-identical cache hits, decoded frame/audio equivalence against a cache-disabled render, caption/title edits, cache-hit cancellation, and hard-cut fallback exclusion.
- On the complete 1080 × 1920 baseline fixture, before/after cold, warm, and caption-edit outputs matched **all 2,381 decoded video frames and 3,450 float-PCM audio frames per output**, including timestamps, durations, and hashes. Every output remained 79.433008 s. Comparison evidence: `finishing-media-validation.json` and the retained per-output `.framemd5`/probe files.
- Dedicated Release builds passed with code coverage disabled. The final control build changes only benchmark configuration/cancellation reporting; production media code matches the fully tested version. Python syntax, changed-file whitespace, and `git diff --check` passed.

The remaining performance work is incremental finishing after edits and broader coverage for music, bumpers, recipe transitions, long footage and live Drive sources. Existing in-place preview memory-cache hits were already effectively instant; this improvement is to repeated renderer executions, not a claim that every Preview button press became 19.6× faster.

Evidence remains local under ignored `build/performance-baseline-runs/2026-09-14/`, with post-scheduler controls in `post-scheduler/`, the first cache batch in `finishing-cache/`, and alternating controls in `paired-finishing/`. Aggregate samples, ranges, counters, memory and binary hashes are in `finishing-comparison-summary.json`. No user media or library database is modified, and no commit or push is made.
