# Performance progress and tradeoffs

September 15, 2026. Implemented changes are in the working tree, uncommitted.
The source used throughout is the available **140.544490-second (2:20.544)**
Du Plessis vs Strickland fight recording. These workloads do not establish
30–60-minute recording behavior.

The tables collect the retained measurements, including regressions. Except
where labeled otherwise, comparisons use five alternating pairs in the same
Release binary. Each feature has its own control; percentages are **not additive**.
“Less time” means lower elapsed time, not an equivalent whole-app speedup.
Small differences and overlapping ranges are observations, not proven effects.
RSS is sampled app-plus-child resident memory, except for the external overlay
prototype, where it covers Python and its descendants.

## Implemented renderer and metadata changes

| Change / measured operation | Before | After | Observed result |
| --- | ---: | ---: | --- |
| [Finishing cache](Performance-Finishing-Cache-Results.md): unchanged render | 13.131 s | 0.670 s | **94.9% less time**; skips assembly and full overlay burn |
| Finishing cache: cold render | 26.845 s | 26.605 s | 0.9% lower median; no established cold improvement |
| Finishing cache: caption edit | 13.576 s | 13.609 s | 0.2% higher median; no edit benefit |
| Finishing cache: sampled peak RSS | 1,608 MiB | 1,609 MiB | Essentially unchanged |
| Finishing cache: cancellation phase, including intentional 1 s delay | 1.059 s | 1.051 s | Similar; not cancellation latency alone |
| [Assembly group cache](Performance-Assembly-Cache-Results.md): caption edit | 13.588 s | 12.270 s | **9.7% less time**; reuses two unaffected crossfade groups |
| Assembly group cache: cold render | 26.833 s | 26.795 s | Essentially unchanged |
| Assembly group cache: unchanged render | 0.672 s | 0.672 s | Unchanged; finishing cache already handles this |
| Assembly group cache: sampled peak RSS | 1,571 MiB | 1,612 MiB | **41 MiB higher (+2.6%)**, with overlapping ranges |
| Assembly group cache: cancellation phase, including intentional 1 s delay | 1.055 s | 1.055 s | Unchanged |
| [Detector cache for export metadata](Performance-Export-Metadata-Results.md): warm metadata | 13.247 s | 0.969 s | **92.7% less time** for metadata recording only |
| Export metadata: warm detector stage (part of preceding row) | 12.340 s | 0.141 s | 98.9% less time; do not count separately |
| Export metadata: cold metadata | 13.186 s | 13.537 s | **2.7% higher median**; no cold improvement |
| Export metadata: sampled peak RSS across cold/warm run | 372.8 MiB | 397.0 MiB | **24.2 MiB higher (+6.5%)**; no memory improvement |
| [Framing cache](Performance-Framing-Cache-Results.md): unchanged render, forty framed clips | 11.588 s | 0.211 s | **98.2% less time**, about 54.8× faster |
| Framing cache: caption edit | 23.357 s | 11.814 s | **49.4% less time**; forty framing hits and thirty-nine segment hits |
| Framing cache: cold render | 35.984 s | 35.961 s | Essentially unchanged (0.06% lower median) |
| Framing cache: warm preparation (part of unchanged render above) | 11.379 s | 0.028 s | Tracking/export replaced by artifact restores; do not count separately |
| Framing cache: sampled peak RSS | 1,224.6 MiB | 1,232.1 MiB | **7.6 MiB higher (+0.6%)**, with overlapping ranges |
| Framing cache: retained scratch cache size | 243.6 MiB | 339.1 MiB | **95.5 MiB more disk (+39.2%)**, within the shared 2 GiB quota |
| Framing cache: cancellation phase, including intentional 1 s delay | 1.450 s | 1.102 s | Lower observed phase time; different pipeline stages, not a general cancellation-latency claim |
| [Finishing ranges on the edit path](Performance-Incremental-Finishing-Results.md): second edit of the same caption | 11.710 s | 2.941 s | **74.9% less time**, about 4.0× faster; 18 ranges restored, 1 encoded |
| Finishing ranges: first edit after a cold render (creates 19 ranges) | 11.695 s | 13.434 s | **14.9% higher median**; one-time range creation |
| Finishing ranges: cold render | 27.292 s | 26.944 s | Unchanged code path; 1.3% lower median is noise |
| Finishing ranges: unchanged rerender | 0.160 s | 0.161 s | Unchanged whole-finishing hit |
| Finishing ranges: sampled peak RSS during the first edit | 825 MiB | 1,400 MiB | **575 MiB higher (+69.7%)** while two range processes run; below the cold render's peak |
| Finishing ranges: sampled peak RSS during the second edit | 838 MiB | 840 MiB | Unchanged |
| Finishing ranges: retained scratch cache size | 290.0 MiB | 310.3 MiB | **20.3 MiB more disk (+7.0%)** |
| Finishing ranges: cancellation phase, including intentional 1 s delay | 1.082 s | 1.074 s | Similar |
| [Detector scan](Performance-Detector-Scan-Results.md): cold scan, concurrent hardware-decoded passes (three pairs) | 21.587 s | 12.848 s | **40.5% less time**, about 1.7× faster; identical events |
| Detector scan: cold scan sampled CPU (core-seconds) | 119.6 | 35.5 | **70.3% less CPU** |
| Detector scan: cold scan sampled peak RSS | 390 MiB | 668 MiB | **278 MiB higher (+71%)** for the scan's duration |
| Detector scan: cancellation phase, including intentional 1 s delay | 1.084 s | 1.087 s | Unchanged |
| [Framing evidence](Performance-Framing-Evidence-Results.md): static camera with framed: tags after portrait fit, 40 scenes (three pairs) | 0.566 s | 0.093 s | **83.5% less time**; 120 Vision requests → 0, identical paths and tags |
| Framing evidence: moving camera without tags, 40 scenes | 5.604 s | 4.857 s | **13.3% less time**; sampling skipped, identical tracked paths |
| Framing evidence: portrait fit, 40 scenes | 1.938 s | 1.862 s | Unchanged; the detections are made here |
| [Segment cache restore](Performance-Segment-Cache-Restore-Results.md): directory scans per warm render (60 hits), standalone timing | 0.026 s at 100 files; 0.314 s at 1,400 files | 0 s | Scan removed from hits; eviction unchanged at publish. Not an application-level pair |

The finishing, assembly and finishing-range fixtures use forty clips with one
framed clip. The framing comparison uses forty framed clips; its times must not
be presented as a direct continuation of the one-framed-clip timing series. The
finishing-range gain applies from the second edit of a timeline onward; the
first edit pays the range creation. These renderer
benchmarks exclude normal export metadata and publication. The detector-cache
benchmark measures metadata separately and preserves all twenty trait vectors.

## Scheduling, analysis and stability

| Work | Evidence | Interpretation |
| --- | --- | --- |
| [Shared media scheduling](Performance-Scheduling-Results.md) | Initial warm render 13.205 s; instrumented post-scheduler control 13.206 s | No render-throughput gain shown; bounds admission and improves queued priorities/cancellation behavior |
| Scheduling under load | Probe median 28.9 ms; requested five-second preview installation 5.001 s; cancel-and-drain 0.387 s over five post-change runs | Endpoint measurements without paired pre-change controls; no percentage gain or p95 claim |
| Local analysis after scheduling | Detector scan 20.790 s; cached read 0.162 ms; thumbnail grid 0.394 s; tracking first 60 s 3.229 s | Existing cache effectiveness and local costs, not newly demonstrated optimization gains |
| Remote AI analysis baseline | 181.33 s of remote-wait elapsed coverage inside a 209.89 s combined phase | Network/model time remains separate; no measured improvement yet |
| [Duplicate timeline-save fix](Performance-Stability-Validation.md) | Reproduced stale-revision failure; regression fails before fix and passes after; no new save errors in fixed-app checks | Correctness improvement; no quantified speed gain |
| Preview identity, sustained dragging and long-source analysis | Initial profiling and functional checks only | No measured p95 improvement or long-recording speedup |
| [Caption source timing through framing](Performance-Framing-Cache-Results.md) | Editing caption 1 previously invalidated all 40 framed segments; corrected runs retain 39 hits and rebuild one | Correct captions on later trimmed clips and **97.5% fewer segment rebuilds** for this edit; this is a work count, not a separate elapsed-time gain |
| [Preview slice validation](Performance-Preview-Key-Results.md) | Twelve cached slices re-keyed after an edit: 2.14 ms at 40 clips, 3.15 ms at 200 clips (Debug build, unit measurement) | Far below one display frame; no change, measurement kept as a regression test |
| [Encode budget](Performance-Encode-Budget-Results.md) | Cold render 28.555 s at 2 jobs, 27.138 s at 3, 26.765 s at 4, 26.397 s at 6; peak RSS 918, 1,274, 1,563, 2,266 MiB (three repetitions each) | Cold render is not bound by encoder concurrency beyond about three jobs; budget kept at four, no renderer change |

The baseline harness, profiling counters and timeout-test hardening improve
measurement or validation; they are not application speedups. Initial baseline
cache-hit timings describe pre-existing behavior and are not attributed to this
implementation series. See [initial measurements](Performance-Baseline-Results.md)
and [post-scheduler local checks](Performance-Finishing-Cache-Results.md).

## Experiments kept out of normal exports

| Experiment / operation | Control | Prototype | Result / decision |
| --- | ---: | ---: | --- |
| [Incremental overlays](Performance-Incremental-Overlay-Prototype.md): early caption-edit finishing | 10.303 s | 2.332 s | **77.4% less stage time**, but not integrated |
| Incremental overlays: cold finishing | 10.303 s | 56.762 s | **5.51× slower**; blocks default adoption |
| Incremental overlays: cold sampled peak RSS | 592 MiB | 2,013 MiB | **3.40× memory**; blocks default adoption |
| Incremental overlays: edited sampled peak RSS | 590 MiB | 580 MiB | 1.7% lower median; does not offset cold cost |
| Decoded PNG looping, one exploratory pair | 10.405 s | 10.312 s | 0.9% lower observed time; insufficient evidence of useful gain, no production change |
| [Cold render](Performance-Cold-Render-Experiments.md): hardware decode for 2 s segments | 0.583 s | 0.754 s | Slower; session setup outweighs sixty frames |
| Cold render: libx264 instead of VideoToolbox for segments, eight at four parallel | 3.280 s | 3.850 s | Slower in parallel; CPU bound |
| Cold render: hardware decode for the full overlay pass | 10.314 s | 10.356 s | No change; filter thread and encoder bound |

The incremental overlay prototype preserved measured timing/audio but changed
encoded video slightly (mean per-frame SSIM 0.998691 on the main fixture).
Its edit-path idea now ships as [finishing ranges](Performance-Incremental-Finishing-Results.md):
input seeking removed the prefix evaluation that made its cold pass slow, and
ranges are created only on the edit path, so cold renders are untouched. Range
outputs carry the same SSIM difference from a continuous encode.

## Latest validation

After the framing-evidence change the full suite ran at **865 tests: 863
passed, one failed, one live Drive test skipped**; the failure is the
load-dependent `framedCaptionOffsets` described below, which passes alone.
The two new framing tests and the six paired analysis runs passed with
identical framing results.

After the detector-scan change the full suite ran at **863 tests: 860 passed,
two failed, one live Drive test skipped**. Both failures are load-dependent
and pass alone: `framedCaptionOffsets` (below) and
`ScriptValidationTests/threeValidationsHaveNoProductionCapability`, whose
script engine hit its own timeout at 12 s under the suite's concurrent ffmpeg
load and completes in 0.07 s alone. The detector and detector-cache tests,
including the new hardware-versus-software equality check, passed. The
encode-budget measurement changed no renderer behaviour.

The finishing-range change ran the full suite at **862 tests: 860 passed, one
failed, one live Drive test skipped**. The failure is `framedCaptionOffsets`,
a pixel-equality check between a framing-cache hit and a fresh rebuild that has
no overlays and never enters the range path; it passes alone and fails alone
under four unrelated concurrent VideoToolbox encodes, so it reflects encoder
nondeterminism under contention rather than the new code. It passed in the
earlier framing-cache run. The seven new range tests passed, the paired
benchmark and media validation are in
[the finishing-range results](Performance-Incremental-Finishing-Results.md).

The framing-cache change passed **853 tests, zero failures, one live Drive test
skipped**, both Release builds, five paired benchmarks, decoded media parity and
production export/database checks. The subsequent unlocked normal Release UI
check also passed: first export 37.739 s, repeat 0.727 s, with framing/segment/
finishing hits, byte-identical outputs and both new metadata records persisted.
These single UI runs use one framed clip and are functional evidence, not an
additional paired speedup or a replacement for the forty-framed-clip comparison.
The app quit normally with no new save-error or hang logs. See the
[UI verification details](Performance-Framing-Cache-Results.md) for isolation and
retained evidence. No new production code changes or test reruns were needed.
