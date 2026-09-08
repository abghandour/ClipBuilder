# Clip Builder performance audit

September 7, 2026. Static review of the current working tree.

The largest opportunities are reducing repeated media decoding/encoding and giving interactive work priority over background jobs. Several earlier optimizations are already present, so replacing the architecture wholesale is unnecessary.

Scope: indexed the app's 206 Swift files, searched across source areas for expensive work, and traced analysis, transcription, framing, Wizard generation, multitrack rendering, thumbnails, Builder interaction, persistence, asset management, and Drive integration. This is a codebase-wide performance audit, not a claim that every line was individually reviewed. No application code was changed. No runtime profiling, representative-media benchmarks, or Xcode tests were run. Priorities describe expected impact; no measured speedup is claimed.

## Priorities

| Order | Improvement | Primary benefit | Effort / risk |
| --- | --- | --- | --- |
| 1 | Cancel obsolete thumbnail work and coalesce identical requests | Scrubbing and selection responsiveness | Medium; preserve Drive leases |
| 2 | Introduce a shared media-work budget | UI responsiveness during analysis/rendering | Medium; prevent starvation/deadlocks |
| 3 | Move autosave encoding and remaining asset I/O off the main actor | Editing, import, and menu responsiveness | Small–medium |
| 4 | Bound analysis image resolution; defer unused fallback frames | Analysis latency and memory | Small–medium; validate recognition quality |
| 5 | Reduce Center Stage input size and reuse detections | Framing/analysis throughput | Large; validate tracking quality |
| 6 | Remove redundant framing and overlay encode passes | Generation throughput and image quality | Large; preserve render parity |
| 7 | Cache rendered segments across previews and revisions | Repeat generation and exact previews | Medium–large; careful invalidation |
| 8 | Virtualize timeline clip views | Long-timeline loading, scrolling, memory | Medium; preserve drag/drop/selection |
| 9 | Reuse local analysis artifacts and overlap independent stages | Analysis and podcast latency | Medium; preserve identity/provenance |
| 10 | Scope database aggregate reads; reduce snapshot churn | Large libraries and editing | Small–medium |

Add stage timing before implementing these, then compare each change against a fixed baseline. This order puts interaction responsiveness first because the reported slowdown on a 12-video library is a freeze complaint, not a throughput complaint; throughput items follow, and specialized effects come last. If profiling shows the freeze is elsewhere, re-rank after the first measurements.

## Analyzer.swift

### A1 — Analysis frames have no resolution cap

**Evidence:** `ClipBuilder/Services/Analyzer.swift:146` calls `ThumbnailService.jpegFrames` without `maxDimension`. Its default is zero, and `ThumbnailService.swift:121` only sets `maximumSize` when the argument is positive. The usual grid contains up to 30 frames; custom sampling allows 120. Notes and marker frames are extracted in additional batches. `AIService.swift:250` base64-encodes images for Claude and then serializes another JSON payload.

**Rule:** Bound the pixels and bytes needed for the analysis task. Claude downsizes images above roughly 1568 pixels on the longest edge before inference, so 4K frames buy no model quality; the win is decode, JPEG encode, upload time, and memory.

**Before → after:** full-source JPEG grid → a configurable, capped analysis grid, initially testing a 1280–1536-pixel longest edge. Preserve more detail for small identity-marker crops and text-reading tasks; crop first where detail matters. Add an aggregate byte budget as well as a frame-count budget.

For scale, a 3840×2160 image has nine times the pixels of 1280×720. That is pixel arithmetic, not a ninefold latency prediction: source decoding, JPEG compression, upload, and model processing have different costs.

**Validate:** same scenes/people/notes on 4K fights, broadcast scoreboards, small faces, and low-light footage. Record extraction time, total JPEG bytes, request size, peak memory, and model latency. Do not change the global thumbnail default and inadvertently reduce portrait-crop accuracy.

### A2 — Native-video requests still pay for fallback stills upfront

**Evidence:** `Analyzer.swift:1154` extracts and requires sampled frames before the native-video decision at `:1279`. When the selected provider is Gemini and the untrimmed file is at most 300 MiB (`Analyzer.swift:1285`), the video is passed through and `AIService.swift:388` skips the frames.

**Rule:** Prepare expensive inputs only when the chosen execution path needs them.

**Before → after:** extract stills, choose video, discard stills for the primary call → determine the input mode first and lazily prepare stills if a fallback provider needs them. The dispatcher needs a lazy input supplier and an explicit capability requirement so a video request cannot accidentally select a text-only provider.

**Validate:** successful native requests make no unnecessary sample-grid extraction; failed native requests still fall back correctly; trimmed requests retain their existing still-frame behavior. Preserve timestamped notes and identity-reference semantics in the prompt.

### A3 — Local passes repeatedly inspect overlapping source ranges

**Evidence:** `Analyzer.swift:1431` breaks down windows serially; `:1615` computes loudness after the AI response; `:1643` computes portrait fit per saved scene; `:1704` tracks Center Stage per scene. `FramingService.swift:79` samples those scenes again during a later framing pass. Parent sequences and child actions can overlap.

**Rule:** Reuse source-level evidence, and overlap genuinely independent stages.

**Before → after:** per-scene frame extraction/detection and repeated full-file loudness → versioned source/timestamp detection records and a cached loudness curve; derive scene results from those records. Use the same sampled evidence for portrait fit and static framing where compatible. Preserve distinct frame sizes/times when the algorithms require them.

Start local audio work during the remote AI wait when it is likely to be needed. Small bounded concurrency can help independent breakdown requests, provided results are merged deterministically and provider limits are respected.

Do **not** simply parallelize the outer video loop in `AppStore.swift:1230`: its known-person roster intentionally incorporates people found in preceding videos. Prefetching the next video's frames/audio is a safer initial overlap. Parallel AI work must also isolate `AIRunCapture` state and preserve provenance.

**Validate:** equivalent saved ranges/tags/camera paths, deterministic new-person identities, cancellation, cache invalidation after source/marker/model changes, and actual wall-clock improvement under the shared resource budget.

### A4 — Every source rescan reads file contents for every video

**Evidence:** `Analyzer.swift:35` recursively enumerates sources (requesting no resource keys) and calls `ContentHash.fingerprint` at `:38` before checking whether the file is already known; the known table is keyed by hash, so hashing is currently a prerequisite for the check. `FFmpeg.swift:275` reads the first and last MiB for each fingerprint. Unchanged files avoid probing but still incur content reads.

**Before → after:** hash every candidate on every scan → cache path/file identity, size, modification time, and fingerprint; hash new or changed candidates. The enumerator must request size and modification-date keys for this to be cheap. The cost matters most on network or external source volumes, where two MiB per file per folder event adds up. Retain explicit deep verification for ambiguous replacements. A metadata shortcut is not proof that contents are unchanged.

**Validate:** unchanged rescans, rename/move detection, a file overwritten in place, partial copies, and slow external source volumes. Coalesce overlapping scans as well as folder events.

## ThumbnailService.swift, Components.swift, and PreviewPane.swift

### U1 — Obsolete scrub requests can continue decoding and writing cache files

**Evidence:** `VideoThumbnail` at `Components.swift:111` and the crop editor at `PreviewPane.swift:185` launch time-keyed tasks. `ThumbnailService.swift:38` checks disk then starts a fresh frame loader, without an in-flight request table. `jpegFrame` creates an image generator per request, and there is no explicit cancellation handler calling `cancelAllCGImageGeneration()`. View tasks do not check cancellation before publishing the loaded image. `ImageCache` also starts detached decode work on a miss without coalescing it.

**Rule:** Latest interactive requests should replace obsolete work, and identical work should be shared.

**Before → after:** every requested timestamp independently decodes and persists → separate interactive preview requests from durable thumbnails; coalesce identical source/time/size requests, cancel obsolete generation, and check cancellation plus the requested key before publishing. Keep the previous displayed frame until its replacement is ready.

During active dragging, request coarse timestamps at a bounded rate, then request the accurate frame on release. Keep transient scrub frames in a bounded memory cache rather than writing every intermediate position to disk. Reuse a small number of source generators where safe.

Cancellation must account for shared consumers: cancel the underlying request only when no consumer still needs it. Keep Drive media leases alive through decoder completion. Bound persistent thumbnail storage with an explicit eviction policy, retaining the existing offline Drive behavior.

**Validate:** fast scrub across multiple sources while analysis runs; the final frame matches the final position, cancelled requests do not overwrite it, process/decoder counts stay bounded, and disk-cache growth is controlled.

## FFmpeg.swift and ProcessRunner.swift

### X1 — Concurrency limits are per operation, not shared across the app

**Evidence:** `FFmpeg.swift:71` defines a two-to-four-job limit. Each `BoundedConcurrency.map` gets its own limit. `RenderEngine.swift:289` and `:358` start additional frame tasks inside rendering work; analysis and preview image generators are outside this limit. `ProcessRunner.swift:84` dispatches each external process independently. Drive uploads have their own two-upload cap (`GoogleDriveTransfers.swift:229`); downloads are not capped by that guard.

**Rule:** Bound total resource consumption and prioritize interactive requests.

**Before → after:** independent local limits → a shared scheduler with separate budgets for media decoding, encoding, local Vision work, and network/AI requests. Interactive playback/thumbnail requests should get priority over speculative prefetch and batch analysis. Tune for memory and thermal pressure as well as processor count.

Avoid holding an outer permit while waiting for an inner task that needs the same permit. Lowering process priority alone does not reserve GPU/media-engine capacity. Start conservatively; increasing concurrency may worsen both completion time and UI latency.

**Validate:** analyze + render + scrub simultaneously on the minimum supported Mac; measure p95 interaction latency, peak memory, process counts, total job time, cancellation, and starvation.

### X2 — Process capture duplicates large audio buffers and keeps all diagnostics

**Evidence:** `ProcessRunner.swift:126` and `:131` capture stdout/stderr to completion. `BeatDetector.swift:27` requests full-track float PCM, then `:37` copies it into a `[Float]` via `Array(raw.bindMemory(...))`. Other audio-analysis paths also decode the source separately.

**Before → after:** retain full raw PCM and a second array → stream energy/embedding computation in chunks, or analyze a shared PCM artifact. Add capture modes: full structured stdout where required, binary streaming for media, and a bounded diagnostic tail for ordinary encodes. Keep full diagnostics where parsers explicitly depend on them, such as scene-change extraction.

**Validate:** long music/podcast files, peak memory, equivalent onset positions, complete structured AI output, and useful error messages. This is secondary to image/encode work for short reels.

## CenterStageService.swift

### A5 — Tracking reads full-resolution BGRA frames before skipping samples

**Evidence:** `CenterStageService.swift:426` requests BGRA with no scaled output. The loop at `:445` calls `copyNextSampleBuffer()` before the `nextAnalysis` check at `:448`. A source frame is therefore decoded before it can be skipped for Vision. The detector runs about 6.7, 10, or 20 times per second according to camera tuning, subject to source cadence.

**Rule:** Match tracking input resolution to detection needs; separate decoding cost from detector cadence.

**Before → after:** full-size decode/conversion followed by sparse detection → evaluate a low-resolution analysis proxy or a supported scaled reader/composition output, then use normalized detections to drive full-resolution export. Retain a sequential decoder when it beats repeated random seeks on long-GOP footage. Merely reducing detector frequency does not remove the preceding decode cost.

Reuse detections across overlapping scenes, but recompute smoothing and identity selection when tuning, hints, or markers change. Cache keys need source identity, analysis version, sampling parameters, and relevant detector settings.

**Validate:** rotated footage, small/distant subjects, fast motion, referee exclusion, missed-subject rate, tracking time, and total time including proxy creation. Do not blindly add unsupported output keys: Apple's [AVAssetReaderTrackOutput documentation](https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput) describes pixel-format and settings restrictions.

## MultitrackRenderer.swift and WizardEngine.swift

### R1 — Framing prepasses are serial and create intermediate encodes

**Evidence:** `MultitrackRenderer.swift:114` reframes eligible clips in a loop before the parallel segment map at `:237`. The area-framing loop at `:171` is also serial. Center Stage exports an MP4 at `CenterStageService.swift:781`; segment rendering subsequently encodes that result. `WizardEngine.swift:3132` similarly exports saved framing and then calls `extractClip` to apply the remaining work. Area and podcast split paths also create intermediates.

**Rule:** Combine compatible transforms before encoding; parallelize independent work within a shared budget.

**Before → after:** reframe → encode temporary MP4 → decode → caption/composite → encode → represent framing as part of the segment renderer's transform plan so eligible clips encode once. Static paths are the lower-risk first target. A moving path may require a custom compositor or carefully validated equivalent transform implementation.

As an interim improvement, run independent prepasses with bounded concurrency and reuse identical prepass results. One `CenterStageService` actor still serializes its synchronous tracking loop, so merely wrapping its calls in a task group will not parallelize all of that CPU work.

**Validate:** saved-path parity, crop geometry, speed, source audio, orientation, HDR/color handling, cancellation, and final output quality. Count actual encode passes rather than inferring throughput from hardware-encoder selection.

### R2 — Builder overlays can trigger another full-timeline encode

**Evidence:** `MultitrackRenderer.swift:264` assembles segments, then `:331` burns text/image overlays in another pass. A transition run may already have encoded the assembled timeline. Wizard clip extraction already burns many overlays and captions together, providing an existing pattern to reuse.

**Before → after:** segment encode → transition assembly → full-length overlay encode → burn eligible overlays into segments, or combine overlays with the final transition graph. Preserve overlay timing across segment boundaries, fade animations, z-order, and overlays that span a transition; these cannot all be moved blindly.

Hard-cut concatenation and music mixing already use `-c:v copy` in `RenderEngine.swift:752`, `:771`, and `:778`; retain those fast paths. Do not propose hardware encoding or stream-copy music as new features.

**Validate:** overlays crossing transitions/gaps, multiple overlapping layers, caption timing, end frames, render duration, and encode count.

### R3 — Repeated renders and exact previews rebuild unchanged media

**Evidence:** render scratch directories are removed at the end of each run. `AppStore.swift:3575` sends exact previews through the full renderer with the same document settings; `MultitrackRenderer.swift:98` always installs `document.renderSettings`. `preview` changes the destination/persistence behavior rather than introducing a lower-cost render configuration. Wizard critique revisions can render another complete version.

**Rule:** Reuse deterministic render artifacts with complete invalidation keys.

**Before → after:** every preview/revision renders everything → bounded persistent segment/prepass cache keyed by source identity, ranges, speed, camera path, masks, overlays, captions, canvas, encoder settings, resource identity, and renderer version. Reassemble only changed parts.

Offer an explicitly labeled draft preview at a lower resolution; retain the existing exact-quality option. Do not silently redefine “Exact Preview.” Cache normalized brand cards and repeated overlay assets where inputs are identical.

**Validate:** unchanged preview reuse, one-clip edits, text/font/mask changes, replacing source files, quality-setting changes, cache eviction, and no reuse of cancelled/partial artifacts.

## TimelineView.swift and AnalyzeView.swift

### U2 — Timeline creates every clip block, including offscreen thumbnails

**Evidence:** `TimelineView.swift:361` uses an eager `ZStack`/`ForEach(layout.clips)`, and each `TimelineClipBlock` (`:385`) contains a `VideoThumbnail` at `:436`.

**Rule:** Instantiate only the visible portion of large scrolling content.

**Before → after:** all timeline clips become views → query clips intersecting the viewport plus a small prefetch margin, using existing timeline layout data. Keep the selected or dragged item alive when needed. A simple `LazyHStack` replacement is inappropriate for overlapping, absolutely positioned clips.

**Validate:** long timelines with hundreds of clips, initial decoder count, scroll hitches, overlap layering, trimming, accessibility navigation, and drag/drop beyond the viewport. Existing playhead leaf views and cached timeline layout should remain.

### U3 — Sources table redoes library-derived work on selection changes

**Evidence:** `AnalyzeView.swift:311` computes batch/transcript/people counts and sorts videos in a computed table property. Its parent also observes selection and analysis state. The work is linear in analysis runs plus sorting, even when only selection changed.

**Rule:** Keep repeated view evaluation cheap and isolate dependencies.

**Before → after:** inline reductions and sorting → a dedicated table view backed by a summary cache invalidated by changes to videos, analysis runs, scene index, and sort order. Keep selection as a lightweight dependency. Existing `SceneIndex` and the Scenes grid memo are useful patterns.

**Validate:** selection latency with many runs/scenes and accurate counts after analysis/deletion. With only 12 videos and few runs, this alone is unlikely to explain a major freeze; profile before prioritizing it over decoder contention.

## AssetBrowserView.swift, AssetLibrary.swift, and ResourceBundleSheets.swift

### U4 — Some asset operations still synchronously block the main actor

**Evidence:** `AssetBrowserView.swift:486` calls `AssetStore.importFiles` from a synchronous UI callback; `AssetLibrary.swift:229` copies the files synchronously. Large music/video assets or external storage can therefore stall the interface. `ResourceBundleSheets.swift:83` computes inventory in `onAppear`. Asset/crop catalog caches also refresh through synchronous directory enumeration when their TTL expires (`AssetLibrary.swift:173`, `ScreenCropStore.swift:186`), including access from UI menus.

**Rule:** Keep filesystem traversal and bulk file copying off the UI executor.

**Before → after:** UI callback → synchronous copy/scan → worker service performs copy/scan → main actor publishes progress or a refreshed immutable catalog. Keep the last catalog available while refreshing and invalidate explicitly after edits. Preserve security-scoped access for the full operation.

`Task { ... }` alone is not a background-work guarantee. The project enables approachable concurrency and defaults to MainActor; make the worker boundary explicit using an actor or an appropriately isolated `@concurrent` function. This follows [Swift SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md). Existing video import and initial font registration already use detached utility work and need not be redone.

**Validate:** import from a slow external disk while selecting scenes; menus remain responsive during catalog refresh; cancellation and partial-file cleanup remain correct.

## TranscriptionService.swift and PodcastAnalysisService.swift

### A6 — Podcast stages repeat audio extraction and serialize independent requests

**Evidence:** `TranscriptionService.swift:105` extracts a language sample; `:195` extracts full 16 kHz mono PCM. `PodcastSpeakerSeparator.separate` at `PodcastAnalysisService.swift:159` extracts the source again to float PCM. Language candidates at `TranscriptionService.swift:111` and exchange chunks at `PodcastAnalysisService.swift:541` run sequentially.

**Before → after:** separate source decode for each consumer → share a versioned normalized audio artifact and derive the short sample from it where beneficial. Transcript caching already exists; extend reuse to audio and speaker evidence rather than adding a duplicate transcript cache. Use small bounded concurrency for independent language candidates or exchange chunks after measuring resource/provider limits.

**Validate:** EN/pt-BR detection, timestamps, speaker turns, long recordings, cached transcription behavior, ordering/provenance of chunk results, and cancellation. Short-sample language detection can still be preferable to eagerly decoding an entire recording; measure time-to-first-result as well as total completion time.

## Database.swift and AppStore.swift

### D1 — Project-scoped scene fetches still aggregate profile-wide tags and grades

**Evidence:** `Database.swift:1660` scopes scene rows by project, but the tag/grade scope at `:1699` is only set when `sceneID` or `videoID` is supplied; the project-only branch at `:1704` leaves it empty, so `:1709` and `:1716` scan the whole profile. A project-only snapshot reads all scene tags and aggregates all grades in the profile.

**Rule:** Apply the same scope to supporting aggregates as to the requested rows.

**Before → after:** project scenes + profile-wide tag/grade scans → constrain aggregates with the same scene/project/exclusion predicates, using joins or a matching scene subquery. Examine query plans before adding indexes: the existing `UNIQUE(video_id, run_id, start_time, end_time)` already provides a leading-video index.

**Validate:** identical returned rows, query counts/plans and timing for a small project in a large profile, hidden-scene behavior, and existing database tests. This is a scaling improvement, not proof of the reported 12-video slowdown.

### D2 — Autosave still encodes the full timeline and reloads list metadata

**Evidence:** `AppStore.swift:3482` synchronously JSON-encodes the full document on the main actor, saves it, and refetches timelines/projects. `BuilderStore.swift:334` already debounces changes by 400 ms. Full refresh also compares complete scene arrays and rebuilds indexes when scene data changes (`AppStore.swift:983`).

**Before → after:** encode full document on UI executor + reload entire lists after each save → encode an immutable snapshot off the UI actor, coalesce writes with version ordering, and update the affected timeline summary directly. Preserve termination flushing and latest-save-wins behavior. Consider revisioned snapshot/index construction off-main only when profiling demonstrates a material cost.

**Validate:** continuous edits, switching timelines during a save, undo/redo, Cmd-Q during a pending save, and library correctness. Existing equality checks, single-scene refresh, coalesced refresh, and `SceneIndex` already reduce churn; keep them.

## Existing strengths to retain

- VideoToolbox preset encoding and explicit libx264 fallback for custom CRF.
- Cached, coalesced ffprobe requests keyed by file identity.
- Batched AVAssetImageGenerator extraction with bounded FFmpeg fallback.
- Parallel segment/clip rendering, same-pass Wizard overlays/captions, stream-copy hard cuts and music.
- Saved camera paths, cached transcripts, onset caching, and transcript-first podcast analysis.
- Off-main image downsampling, memory thumbnail cache, isolated playback clocks, scene indexes, and memoized timeline/grid calculations.
- Database actor isolation and WAL, targeted scene updates, debounced autosave/log batching, and throttled Drive progress.

## Measurement and implementation sequence

1. Add signposted timings for scan/hash, frame decode/JPEG encoding, AI input preparation, remote wait, transcription, Vision, framing export, segment encode, assembly, overlays, snapshot application, and thumbnail requests. Track cache hits, cancellations, encoded pixels, intermediate bytes, peak memory, and active jobs. The existing `PerformanceAnalytics` service measures Instagram results, not runtime performance.
2. Establish fixed fixtures: short 4K fight, long landscape fight, rotated phone clip, MKV fallback, long podcast, and a many-clip timeline with overlays/captions/transitions. Include external source media with the existing internal-only data-folder policy. Keep benchmarks in an isolated data folder.
3. Measure Release builds both idle and while analysis/rendering run. Record median and p95 interaction latency, total stage time, and cold/warm-cache behavior over repeated runs. Capture Time Profiler/SwiftUI hitches and a process sample on the affected Mac; its current source-storage path and hardware remain unknown.
4. First implementation batch (responsiveness): cancellation/coalescing for thumbnails, off-main autosave encoding and asset imports, and a conservative shared resource scheduler. Confirm p95 interaction latency improves under concurrent analysis/rendering without unacceptable background-work starvation.
5. Next (throughput, contained): analysis image budget and deferred fallback frames, project-scoped SQL aggregates, and timeline viewport virtualization. The SQL change is a scaling fix, not a freeze fix; keep it here because it is cheap, not because it addresses the report.
6. Then: source analysis caches, Center Stage input optimization, render-stage fusion, persistent segment caching, and podcast overlap. Each needs output/recognition regression checks in addition to timing.

Success means faster measured completion and interaction latency while preserving detection quality, framing, audio sync, editable timelines, cancellation, Drive ownership, and render correctness. Do not promise a speedup multiplier until representative runs establish it.
