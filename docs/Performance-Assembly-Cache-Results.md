# Crossfade group reuse after caption edits

September 14, 2026. Follow-up to [finishing-result caching](Performance-Finishing-Cache-Results.md).

The subsequent [incremental overlay prototype](Performance-Incremental-Overlay-Prototype.md) is an opt-in experiment; these production-path results remain the application baseline.

## Change

A caption edit invalidates the complete finished video. Previously, assembly then re-encoded every crossfade group, even when the edit affected a different clip. Assembly now restores unchanged crossfade groups and re-encodes only groups whose inputs changed. Hard cuts continue to use the existing stream-copy concatenation; the full-timeline overlay burn still runs after an edit.

Keys hash the complete ordered segment files, transition names, captured transition duration, optional maximum overlap, render settings, encoder arguments and segment renderer version in the `multitrack-assembly-v1` namespace. Groups are independent of their absolute timeline position because their output contains segment content and local crossfades; global overlays remain in the later pass. Segment and overlay filter graphs are unchanged.

The caller stages newly encoded groups in render-owned scratch storage and publishes them only after a complete successful render, using the existing source-fingerprint checks, cancellation handling, atomic publication and shared 2 GiB LRU budget. Failed crossfades are never staged as successful transition outputs. A cache I/O failure does not turn a successful crossfade into a hard-cut fallback. New artifacts share the segment/finishing quota and can increase eviction pressure.

Builder enables group reuse for reusable segment inputs without music, bumpers or recipe transitions. Those exclusions match the initial finishing-cache scope. An edit within a group rebuilds that entire group; an all-crossfade timeline has only one group, limiting the benefit. Full finishing-cache hits still skip assembly altogether.

## Measurement method

The accepted source remains `Du Plessis vs Strickland R5 - UFC Middleweight Championship.MP4`, **140.54449 seconds (2:20.544)**. The fixture is unchanged: forty clips, two fades, captions, a global title, an overlay block and Center Stage framing, rendered at 1080 × 1920.

Use five alternating enabled/disabled runs in the same Release profiling binary, fresh application caches per run, `--scope none`, and no builds/tests during capture. `--disable-assembly-cache` provides the control; the complete finishing cache stays enabled in both modes. Do not interpret the unchanged warm-cache path as a new improvement from assembly reuse.

A preliminary standalone PNG-loop experiment took 10.405 s with repeated decoding versus 10.312 s with a decoded-frame loop in one pair. This did not establish a useful gain, so no PNG-loop change was added to production.

## Validation and results

- Full `scripts/test.sh`: **841 passed, 0 failed, 1 skipped** (the opt-in Google Drive round trip). Result bundle: `/private/tmp/clipbuilder-assembly-full.xcresult`.
- Eleven focused tests passed. New coverage verifies reuse after an unrelated caption edit, invalidation after an edit within the transition group, zero crossfade encodes on a group hit, decoded video/audio equivalence against disabled reuse, cancellation during a hit, and exclusion of hard-cut fallbacks from staged entries. Cache identity coverage includes maximum overlap.
- Release profiling build passed with code coverage disabled. Python syntax and `git diff --check` passed.

### Five alternating pairs in one Release binary

Executable SHA-256: `bc854bd2df1531e3f742bc80cf9eba90d60aa1f839625547f6a02d52315fdbd3`. All ten runs completed, with the same source, timeline and capture scope.

| Phase | Group cache disabled, median (range) | Group cache enabled, median (range) |
| --- | --- | --- |
| Cold render | 26.833 s (26.537–27.185) | 26.795 s (26.216–27.532) |
| Unchanged rerender | 0.672 s (0.665–0.695) | 0.672 s (0.669–0.700) |
| One caption edit | 13.588 s (13.544–13.649) | 12.270 s (12.236–12.373) |
| Cancellation phase, including intentional 1 s delay | 1.055 s (1.039–1.077) | 1.055 s (1.015–1.070) |
| Sampled peak app + child RSS | 1,571 MiB (1,519–1,599) | 1,612 MiB (1,526–1,618) |

The caption-edit render fell from **13.588 s to 12.270 s: 1.318 s saved, or 9.7% less elapsed time**. Every enabled edit reused both unchanged crossfade groups, reducing successful video encodes from four to two. The changed caption segment and the full overlay burn still encode. This is an incremental assembly improvement for edits outside those groups, not incremental rendering of the complete overlay pass.

Cold, warm and cancellation medians were similar. The sampled peak RSS median was about 41 MiB higher with reuse, with overlapping ranges; these runs establish no memory improvement. RSS samples are 500 ms snapshots of the app and descendants, not exact peak allocations. No new preview responsiveness, p95, long-recording, or excluded-path claim is made.

Each run used fresh application caches; the OS file cache was not purged. Alternating order reduces run-order bias but does not control background activity or thermal state. Existing whole-finishing cache reuse remains enabled in both modes and explains the roughly 0.67 s unchanged rerender.

### Correctness

The complete 1080 × 1920 fixture matched between enabled and disabled modes for cold, warm and caption-edit outputs: **all 2,381 decoded video frames and 3,450 float-PCM audio frames per output**, including timestamps, durations, byte counts and hashes. Every output remained 79.433008 seconds. Evidence: `media-validation.json` and retained `.framemd5`/probe files in each mode’s first run. This verifies the measured fixture; it does not establish equivalence for every container, encoder or transition combination.

Evidence is retained locally under ignored `build/performance-baseline-runs/2026-09-14/paired-assembly/`: ten run directories, `summary.json`, per-phase counters/logs, executable hashes and sampled RSS. The comparison script is `../compare-assembly-media.py`. No user media or library database was modified. Changes remain uncommitted.

