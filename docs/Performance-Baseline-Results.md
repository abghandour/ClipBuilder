# Initial video performance baseline

Subsequent measurements and finishing-cache validation are documented in [Performance-Finishing-Cache-Results.md](Performance-Finishing-Cache-Results.md).

September 14, 2026. Revision `c9eac1a`, with the opt-in baseline harness in the working tree. This implements the first step of the combined recommendation: capture the current application before optimizing it. No production pipeline optimization is included.

## Findings that affect priority

1. **The final overlay pass dominates this fixture's warm render.** All 40 segments hit cache, but `OverlayBurn` still took **10.29 seconds** of a **13.20-second** render. Assembly took **2.16 seconds**. This supports investigating transition-compatible segment overlay fusion and reuse of completed assembly/overlay artifacts. Correctness around fades remains a gate.
2. **Framing still runs before warm segment hits.** Each render performed 19 `Vision` intervals and one framing export, including the unchanged render and caption edit. The warm export took **0.32 seconds** here. This confirms the redundant work, but its cost is smaller than the final overlay pass when only one clip uses Center Stage.
3. **Remote analysis time must stay separate from local work.** Three `AIRemoteWait` intervals covered **181.33 seconds of elapsed time** within the **209.89-second** analysis/framing phase. Their durations sum to 247.71 seconds because the two breakdown requests overlap. The trace contains **1,636 application `Vision` intervals**, summing to **21.01 seconds**; these are interval counts, not decoded-frame counts.
4. **Cold detector work is substantial; its database cache works.** The explicitly requested full detector bundle took **21.22 seconds**, and the unchanged cached read took **0.16 ms**. This independently exercises the detector service; it does not establish that the normal Analyze screen needs this scan for a short input with Smart Sampling inactive.
5. **The drag trace does not establish JSON encoding as the main UI cost.** In the timestamped 2.49-second drag and subsequent drawing window, the focused trace contained 716 one-millisecond main-thread samples. Display updates, Core Animation, and SwiftUI's attribute graph dominate the sampled stacks. No `JSONEncoder`-named frame matched that window; inlining and the short sample prevent treating this as proof of absence. Keep preview identity/key changes as hypotheses to test, rather than assigning them a measured gain.

## Workload and machine

- Apple M4 Pro, 24 GiB RAM; macOS 27.0 build `26A428`; Xcode beta at `/Applications/Xcode-beta.app`; FFmpeg 8.1.2.
- Release build, coverage disabled, separate bundle identifier, injected scratch database, local source storage. No user project was opened for modification.
- Source: `Du Plessis vs Strickland R5 - UFC Middleweight Championship.MP4`, **140.54449 seconds (2 minutes, 20.544 seconds)**, **2868 × 1320**. Duration is verified against `analysis-01/manifest.json` → `sourceProbe.format.duration`. On September 14, 2026, the user accepted available fight footage for this baseline; a 30–60-minute recording is not a prerequisite. These results describe this short fight clip and do not establish long-recording throughput or memory behavior.
- Analysis used the configured Claude CLI analysis route (`claude-haiku-4-5-20251001`), an initial 29-frame grid, and two dense breakdown grids of 100 and 96 frames. It recorded camera paths for 15 scenes; one additional scene tracked too poorly. The harness enables scene tracking directly in the analysis service, so this combines analysis and framing work.
- Render fixture: forty two-second clips, captions, two fades, a title, an overlay block, and one Center Stage clip. Preview rendering produced H.264/AAC files at **1080 × 1920**, all **79.433008 seconds** long. The nominal timeline is 80 seconds; transitions affect assembled duration.
- Cold means fresh application artifact caches. The operating-system file cache was not purged. Captures ran sequentially, with builds finished before retained benchmark phases.

## Measured phases

| Render phase | Wall time | Segment cache hits | Successful segment encode logs | Successful FFmpeg video encodes¹ |
| --- | ---: | ---: | ---: | ---: |
| Cold | 26.570 s | 0 / 40 | 40 | 43 |
| Unchanged | 13.205 s | 40 / 40 | 0 | 3 |
| One caption edited | 13.585 s | 39 / 40 | 1 | 4 |

The caption change preserved all other transcript entries. Both warm cases still ran a framing prepass, assembly, and full-timeline overlays. `SegmentEncode` signposts occurred 40 times even on the fully cached run: that interval includes preparation/cache lookup and is not an encode counter.

| Other measurement | Observation |
| --- | ---: |
| Cold full detector bundle | 21.216 s |
| Cached detector bundle | 0.000159 s |
| AI analysis, breakdown, portrait fit, and scene tracking | 209.894 s |
| Cold preview preparation, unattended capture | 3.619 s |
| Cached preview restart, unattended capture | 0.000858 s |
| Unattended playback observation | 20.010 s; playhead reached 19.20 s and remained active |
| Render cancellation acknowledgement² | 51.8 ms |
| Detector cancellation acknowledgement² | 69.7 ms |
| Preview cancellation phase², unattended capture | 615.4 ms, including the intentional 300 ms pre-cancel delay |

¹ Successful commands through the task-local `FFmpeg.run` callback with an explicit non-copy `-c:v`. Excludes AVFoundation exports, probes, direct `ProcessRunner` calls, and failed/cancelled commands. UI/prefetch tasks can escape or outlive the measured task context; zero playback counters do not mean zero background encodes.

² Render/detector acknowledgement measures the interval from cancellation request to the awaited task result. It does not prove that all possible underlying media work or fallbacks stop promptly under mixed load.

| Capture | Maximum sampled simultaneous app + descendant RSS³ |
| --- | ---: |
| Analysis | 1,809.8 MiB |
| Render | 1,557.1 MiB |
| Unattended playback | 1,284.7 MiB |
| Playback with drag, system-wide capture | 1,153.8 MiB |

³ Samples every 500 ms; shared pages may be counted twice and brief peaks can be missed. The analysis peak included two overlapping Claude CLI processes. These are resident-memory observations, not allocation peaks or app-only memory.

## Interaction and unresolved observations

The drag was delivered through real mouse events to the foreground scratch app, with before/after window screenshots. Moving the clip stopped exact preview; the remaining part of the 20-second observation window therefore includes editing/idle work. It is not 20 seconds of uninterrupted playback under sustained dragging. An unattended control separately demonstrated continued playback.

Both drag runs logged `ApplyFailure.staleRevision` while saving the scratch timeline. The focused drag run also failed to exit within its external deadline after completing all workload phases. These are unresolved observations; this baseline does not claim that persistence or shutdown passed. The focused CPU analysis uses only the recorded drag window, excluding the later shutdown wait. The focused unattended control completed normally.

The beta Instruments build saved system-wide traces and exported complete application signpost intervals, but crashed with exit 133 while exporting the system-wide CPU-stack table. The focused app capture exported valid CPU stacks; its custom-signpost table was empty. Stage timings therefore come from system-wide captures, and drag CPU observations come from the separately timestamped focused capture. No p95 gesture latency or hang-free claim is made.

## Retained evidence and reproduction

The [runner instructions](Performance-Baselines.md) describe building and recording fresh cases. Retained local evidence is under `build/performance-baseline-runs/2026-09-14/` (ignored by Git):

| Directory | Purpose |
| --- | --- |
| `analysis-01` | Full short-source analysis, detector cache/cancellation, exported signposts and stage summary |
| `render-02` | Clean completed render capture, stage summary, three retained videos, FFprobe checks |
| `playback-01` | Unattended system-wide playback control |
| `playback-drag-01` | System-wide drag capture, screenshots, stage summary; partial failed CPU export labelled `.partial.xml` |
| `playback-focused-01` | Focused drag CPU trace, valid CPU export and `cpu-summary.json`; shutdown deadline failure |
| `playback-focused-control-01` | Completed focused unattended control and valid CPU export |

Manifests preserve original run paths, machine/source metadata, and revision/dirty status. Directories were moved into the ignored build folder after capture. Exported TOCs have environment nodes removed; raw traces remain private machine artifacts. Early build/smoke attempts and the first render with an earlier harness shutdown bug are excluded from these results.

Validation: normal and opt-in Release builds passed; the final profiling build had no `-profile-generate` compile flags. Analysis, render, and system-wide drag traces each exported all four workload phase intervals. Render outputs were probed and a rendered frame was inspected. Python syntax and fresh-directory refusal were checked. Existing Xcode unit/integration suites were not run; no shipping media algorithm changed.

For statistically stable results on the accepted fight fixture, collect at least five independent repeats for local-stage medians and longer controlled gestures for latency distributions. A 30–60-minute fight input and the rotated/fallback-container/podcast/Drive cases remain additional coverage for the broader plan, not prerequisites for using this baseline. No optimization speedup is claimed from these initial runs.
