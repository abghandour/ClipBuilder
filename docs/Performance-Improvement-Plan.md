# Video performance improvement plan

September 14, 2026. Reviewed revision `c9eac1a` (Release 1.75, build 77).

The strongest remaining opportunities are avoiding work before cache hits, sharing local video evidence, and making the existing resource scheduler cover every expensive media path. Increasing concurrency should follow measurements of those changes.

This is a static review and implementation plan. No application code was changed, and no runtime profiling, representative-media benchmarks, or Xcode tests were run. Code paths below are confirmed from source; their contribution to real-world latency is a hypothesis until measured. The review indexed the current 382 Swift source files and traced the analysis, podcast, Wizard, Builder render/preview, media scheduling, caching, and related UI/persistence paths. It is not a line-by-line review of every file.

## Current baseline

The September 7 [performance audit](Performance-Audit.md) is historical. Several of its recommendations are now implemented:

- Analysis stills default to a 1536-pixel longest edge and a 24 MiB aggregate JPEG budget. Automatic sampling stays at 30 frames; custom requests have 100-image and 150,000 estimated image-token bounds. Native Gemini analysis lazily prepares fallback stills. See `AnalysisImageBudget.swift`, `AnalysisFrameSource.swift`, and `Analyzer.swift:73,1453`.
- `MediaWorkScheduler.swift` provides shared decode, encode, and Vision permits, with a decode slot reserved for interactive work. Thumbnail requests coalesce and cancel their AVFoundation generation.
- Center Stage attempts scaled tracking buffers with a 960-pixel longest edge and uses async Vision requests (`CenterStageService.swift:430,494`).
- Source fingerprints, detector results, loudness, transcripts, and normalized audio have caches. Beat detection streams PCM instead of retaining the entire waveform.
- Builder has a persistent 2 GiB segment cache, grouped framing prepasses, fused static area framing, and segment-local overlay fusion. Exact preview renders five-second windows, keeps up to 12 completed slices, and prefetches the next slice.
- Ordinary timeline autosave encodes off-main, main clip lanes use viewport filtering, and runtime signposts already exist.
- VideoToolbox encoding and stream-copy hard-cut concatenation/music are already present. Preserve them.

## Recommended order

Effort is relative: S = contained service change; M = several coordinated changes; L = substantial renderer or evidence-model work. Impact is expected, not measured.

| Order | Work | Primary benefit | Effort / risk |
| --- | --- | --- | --- |
| 0 | Establish a repeatable stage-level baseline | Makes subsequent priorities testable | S–M / low |
| 1 | Close scheduling and cancellation gaps | Responsiveness while processing video | M / medium |
| 2 | Resolve cache hits before framing and raster preparation | Warm renders and preview startup | M–L / medium |
| 3 | Reuse Vision detections; skip unused framing samples | Wide-video analysis and framing | M–L / medium |
| 4 | Avoid unnecessary detector passes and combine required scans | Cold analysis of long recordings | M / medium |
| 5 | Reduce Wizard intermediate encodes and share render artifacts | Generation and critique revisions | L / high |
| 6 | Overlap independent podcast stages and process frames in chunks | Podcast latency and peak memory | M / medium |
| 7 | Remove repeated preview-key work from the main actor | Editing responsiveness with cached previews | M / medium |
| 8 | Coalesce remaining cache misses and bound cache maintenance | Concurrent jobs and long-term storage | M / medium |

## 0. Measure the existing pipeline

**Evidence:** `PerfSignpost.swift` and existing call sites cover source scan, frame extraction, AI input/remote wait, transcription, Vision, framing export, segment rendering, assembly, overlays, and UI selection. `MultitrackRenderer.swift:1084` starts `SegmentEncode` before caption preparation and cache lookup, so that interval is not pure encoding time. `FFmpeg.commandCompleted` counts successful FFmpeg calls but cannot account for AVFoundation exports.

**Change:** Retain the existing instrumentation and add run IDs, separate queue-wait/preparation/execution intervals, and counters for cache hits, decoded samples, Vision invocations, FFmpeg encodes, AVFoundation exports, intermediate bytes, cancellations, and fallbacks. Measure app and child-process memory together. Report AI payload bytes, request count, retries, and remote time separately from local work.

Use Release builds and an isolated data folder. Keep fixed fixtures for short 4K action, a 30–60-minute recording with overlapping scenes, rotated phone footage, MKV/WebM fallback, a long two-speaker podcast, and a large timeline with captions, overlays, moving crops, bumpers, and transitions. Exercise local and Drive-backed inputs, including cold downloads.

For each fixture capture cold run, unchanged repeat, single edit, cancellation, and processing while scrubbing. Use at least five repeated runs for stable local-stage medians and a longer interaction trace for p95 latency. Record machine, memory, source storage, codec, encoder, render settings, provider/model, thermal state, and cache state. Network variation must not masquerade as a local optimization.

Apple recommends keeping discrete synchronous main-thread work under roughly 100 ms and continuous work within a display refresh interval; use these as responsiveness guardrails, not promised video-render times. Capture Time Profiler, Hangs/Hitches, and SwiftUI traces. See [Apple’s responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).

## 1. MediaWorkScheduler.swift, ProcessRunner.swift, CenterStageService.swift

**Rule:** Every expensive leaf operation must participate in the resource budget, and cancellation must stop the underlying work.

**Evidence:**

- `ProcessRunner.swift:110` charges both FFmpeg and ffprobe to `.encoding`, including JPEG fallback and audio-only extraction. Short probes can wait behind long encodes.
- `CenterStageService.swift:771` exports with AVFoundation without an encoding permit. Its `await export.export()` at line 840 has no explicit task-cancellation bridge in this wrapper.
- `PodcastAnalysisService.swift:498` performs face-landmark requests outside the Vision budget.
- `AppStore.swift:4282,4394` sends requested previews and speculative prefetch through the same default background media priority.

**Before → after:** incomplete leaf coverage and undifferentiated process permits → explicit resource classification, shared export permits, and distinct requested-preview/prefetch priority.

Add a small probe budget or reserved admission path; do not let this become an unlimited back door for decoders. Admit AVFoundation exports only at the export leaf. Add missing Vision coverage, bounded fairness for background jobs, and metrics before tuning capacity or thermal adaptation. Avoid nested acquisition of the same budget.

Use the supported throwing async export API where appropriate and test propagation to its originating task. Apple documents cancellation behavior for [export(to:as:isolation:)](https://developer.apple.com/documentation/avfoundation/avassetexportsession/export%28to%3Aas%3Aisolation%3A%29). Audit fallback catches so cancellation cannot start another crop/encode attempt. Retain Drive leases until the decoder/export actually finishes.

**Accept when:** instrumented FFmpeg plus AVFoundation exports obey the configured limit; cancelled or superseded previews release capacity; probes and requested thumbnails remain responsive during export; background work still completes. Include mixed FFmpeg/AVFoundation load and cancellation races in tests.

## 2. MultitrackRenderer.swift and RenderSegmentCache.swift

**Rule:** A cache hit should bypass the expensive work it represents.

**Evidence:** Dynamic framing runs at `MultitrackRenderer.swift:225–297`, before segment construction and cache lookup at line 1175. Prepasses are deduplicated within one render, but their temporary files are deleted at its end. Caption rendering, masks, overlay PNGs, and PNG hashing also precede the lookup (`:351,1110–1175`).

**Before → after:** frame/export clips → prepare rasters → discover a cached segment → plan dependencies → check completed artifacts → prepare only missing dependencies.

Start with a persistent prepass cache using original source identity, source interval, path/area geometry, tuning, output canvas, export configuration, and algorithm version. The current grouping key is not automatically a complete persistent-cache key. Then separate segment planning from execution so fully cached segments need no prepass at all. Cache caption/overlay/mask rasters with complete style and resource dependencies.

Normalize keys to the actual local render inputs where safe. Current segment keys include absolute timeline start and clip placement fields (`RenderSegmentKey` and `MultitrackRenderer.swift:1169`), so moving otherwise identical content or rendering a window can prevent reuse. Preserve ordering, fades, transition handles, and subtitle timing; do not remove fields merely to increase hit rate. A five-second slice cannot automatically satisfy an entire longer export segment.

**Accept when:** an unchanged dynamic-framing render executes zero framing exports and zero segment encodes after warming the relevant caches. A caption-only edit reuses framing; a one-clip edit preserves unrelated segment hits. Source, path, font, mask, effect, canvas, and quality changes invalidate dependent artifacts. Failed/degraded/cancelled outputs never satisfy a full-quality key.

Extend the existing `RenderSegmentCacheTests` and `MultitrackRenderTests`: their static-area warm-cache test does not establish dynamic-prepass reuse. Count AVFoundation exports as well as FFmpeg encodes.

## 3. Analyzer.swift, FramingService.swift, SampledFrameCache.swift

**Rule:** Share source evidence, then derive task-specific decisions from it.

**Evidence:** `Analyzer.portraitFit` (`Analyzer.swift:2184`) and `FramingService.sampleFrames` (`FramingService.swift:239`) request the same three fractional timestamps at 720 pixels and each runs human detection. `SampledFrameCache` stores JPEGs, not detections. Framing samples are prepared for every scene (`FramingService.swift:89`), including moving-camera runs with `tagFramedPeople == false`, where the later tracked path does not consume them. Moving paths are computed per range (`Analyzer.swift:2078`; `FramingService.swift:213`), including potentially overlapping parent/child scenes.

**Before → after:** reused JPEGs but repeated Vision work and per-scene tracking → shared normalized detections/signatures, plus per-scene identity selection and smoothing.

First skip the three still samples when neither static framing nor framed-person tagging needs them. Add a bounded detection cache keyed by source identity, timestamp, size, orientation, Vision request/revision, and detector options. Normalize coordinate conventions explicitly. Store raw evidence separately from user-dependent filtering.

For moving tracking, collect evidence over merged source intervals and derive each scene’s path from it. Preserve scene-boundary smoothing, focus/avoid portraits, manual hints, and tracking cadence. Current scaled buffers already reduce input size; benchmark proxy creation or alternative decoding only if decoding still dominates. Lower Vision cadence alone does not avoid `copyNextSampleBuffer()` for preceding frames (`CenterStageService.swift:477`).

**Accept when:** identical portrait-fit/framing samples invoke Vision once; overlapping ranges reuse evidence without changing scene-boundary behavior; subject selection and crop coverage remain equivalent on small faces, fast action, rotated footage, and referee-heavy scenes. Re-analysis must respond correctly to changed markers and hints.

## 4. AppStore.swift, VideoDetectors.swift, FFmpeg.swift

**Rule:** Run only required detectors and share decoding when several detectors need the source.

**Evidence:** `AppStore.swift:1551` fetches the complete cached detector bundle when analysis only requests cuts. On a miss, `VideoDetectors.swift:67` runs black/freeze detection, then separately invokes scene-change scanning at line 80. `FFmpeg.swift:196` performs another full-file video pass. The DB cache at `AppStore.swift:3011` already avoids repeated successful scans, so this is principally a cold/invalidated-cache cost. The early Smart Sampling check also passes `nativeVideo: false`, before the later native-video decision in Analyzer.

**Before → after:** full detector bundle with two passes → choose required evidence after resolving analysis mode; use one decode for a requested full bundle.

Offer cuts-only and full-detector work plans with compatible versioned cache entries. When all signals are needed, evaluate a combined filter graph with branches that preserve each detector’s input sequence. Disable unused audio processing for visual scans. FFmpeg documents the relevant [split, select, blackdetect, and freezedetect filters](https://ffmpeg.org/ffmpeg-filters.html); equivalence of the proposed combined graph still requires testing. Keep the older-build freeze fallback.

Parse detector events incrementally if diagnostics prove material. A bounded stderr tail alone would silently discard early events. Choose timeouts from duration and measured throughput instead of relying solely on the current fixed 120/300-second limits.

**Accept when:** the full detector bundle decodes once, cuts-only work avoids black/freeze filters, native-video analysis avoids unused Smart Sampling preparation, and warm reads launch no detector processes. Verify event timestamps and trim decisions on black/frozen intros, hard cuts, variable frame rates, no-audio media, and fallback builds.

## 5. WizardEngine.swift, AreaFramer.swift, RenderEngine.swift

**Rule:** Apply compatible transforms before encoding and share artifacts across revisions.

**Evidence:** `WizardEngine.swift:3014` extracts all clips into run-specific scratch space. Saved framing exports and then calls `extractClip` (`:3410–3415`); area layouts add framing, extraction, and composition (`:3354–3395`). Critique can generate up to three versions (`:2371`). The ordinary Wizard extraction path does not use the Builder segment cache. The bumper route sends already extracted clips through MultitrackRenderer (`:3123`), creating another compositing opportunity. Builder overlays spanning segments still use a final pass (`MultitrackRenderer.swift:488`); the integration test intentionally demonstrates two segment encodes, an xfade encode, and an overlay encode.

**Before → after:** independent Wizard intermediate chains → shared render planning and cacheable clip/segment artifacts.

Introduce reusable render operations incrementally: static crop/scale/speed/mask/captions first, then saved moving paths and multi-area layouts. Prefer the existing timeline document as the common input where semantics match. Preserve Wizard-specific cards, source audio, overlays, editable-document persistence, and critique provenance. Cache clip extraction across critique versions before attempting a wholesale renderer consolidation.

After that, evaluate combining transition-spanning overlays with final assembly. Keep the stream-copy path when there are no video-changing operations. Complex transitions need measured output clocks, bumper exclusions, correct z-order, and overlap handles; moving every overlay into an earlier clip is unsafe.

**Accept when:** unchanged Wizard clips are reused across revisions; static transforms use one encode; intended moving/layout paths have fewer measured encode passes. Validate decoded frames with tolerances and visual review, plus duration, color/orientation, crop geometry, subtitle timing, A/V sync, bumpers, and output quality. H.264 file-byte equality is not an appropriate general parity test.

## 6. PodcastAnalysisService.swift and TranscriptionService.swift

**Rule:** Overlap independent stages while bounding retained image data.

**Evidence:** `PodcastAnalysisService.swift:29–50` sequences transcription, speaker separation, remote people identification, and visual motion analysis. Once speaker turns are known, visual analysis needs the turns and video but not the identity response. `:434–454` extracts up to 320 turn frames into one array before consuming them. This is bounded, but remains a sizeable batch. Transcription and separation already share normalized audio.

**Before → after:** people request → decode all turn frames → consume frames → people request overlaps bounded visual frame batches.

Start visual analysis alongside remote identity work after separation, then join before resolving people to turns. Decode/consume turn pairs in small ordered chunks, retaining metrics instead of all JPEGs. Preserve the current sampling coverage initially. Cache versioned speaker embeddings/visual metrics for re-runs that only change highlight or hold settings if profiling justifies it.

Keep language-candidate transcription serial initially: its code explicitly protects shared Speech asset installation and collector ordering (`TranscriptionService.swift:122`). Optimize its repeated sample/full transcription only after timing confirms a material cost. Precompute repeated Hann windows and band coefficients in `embedding` if CPU profiling identifies that loop.

**Accept when:** visual work overlaps remote identity latency, retained frames are bounded by chunk size, and speaker/layout assignments, complete exchanges, cancellation, and people provenance remain correct. Preserve existing podcast integration fixtures.

## 7. AppStore.swift and BuilderWorkspacePreview.swift

**Rule:** Keep revision-driven work cheap on the UI actor.

**Evidence:** `BuilderWorkspacePreview.swift:105` prunes previews on every model revision. `AppStore.swift:4452` recalculates a key for every cached slice. Each key windows the document, scans scene facts, resolves clips, and JSON-encodes/hashes evidence (`:4484`). Up to 12 slices can repeat this work per edit. Ordinary autosave already uses off-main encoding (`:3994`).

**Before → after:** re-window and hash every slice synchronously → revision snapshots, dependency-based invalidation, and coalesced off-main hashing.

Index which clips/scenes/assets affect each slice. Validate only affected slices, compute hashes on immutable snapshots, and apply results only if their revision still matches. Retain immediate protection against stale playback. Include source/resource/transcript/transition-setting revisions: the current slice key describes document/scene/profile facts but not every external renderer dependency. Faster lookup must not expand stale reuse.

**Accept when:** the same edit invalidates the correct slices, stale background calculations never publish, unrelated cached slices remain reusable, and Time Profiler shows no material key-building work on the main thread during dragging. Test edits while playback/prefetch is active and replacements of external render inputs.

## 8. Cache services and thumbnail storage

**Rule:** Concurrent consumers should share production, and cache maintenance should not grow with every hit.

**Evidence:** `NormalizedAudioCache.audio` awaits FFmpeg before publishing, allowing overlapping misses to produce duplicate WAVs. `AnalysisFrameSource.frames` and `SampledFrameCache.jpegFrames` similarly cache completed values without tracking work in flight. `RenderSegmentCache.restore` scans and sorts the cache directory on every successful restore. `SourceIdentityCache.fingerprint` rewrites its full JSON identity index for each newly fingerprinted source. Thumbnail disk writes remain per successful timestamp, and `ThumbnailService` has no byte-limit eviction path.

**Before → after:** duplicate producers and repeated filesystem maintenance → per-key shared producers, consumer-aware cancellation, and amortized bounded maintenance.

Prioritize normalized audio and render/prepass production, where duplicate work is expensive. Add byte budgets and leases for evidence/audio artifacts; batch identity-index persistence; maintain segment-cache size/LRU metadata or sweep periodically instead of on every hit. Separate transient scrub frames from durable thumbnails and preserve offline Drive thumbnails under an explicit policy. Use fresh file attributes for invalidation and test source replacement; metadata shortcuts are not deep content verification.

**Accept when:** two simultaneous consumers launch one producer, cancelling one consumer preserves the other, failed producers can retry, active artifacts survive eviction, cache growth remains bounded, and large-library imports/restores avoid repeated full-index/directory work.

## Delivery sequence and regression gates

1. **Baseline and responsiveness:** instrument missing boundaries, then implement scheduler/export cancellation coverage and preview-key work. Re-rank throughput work using traces.
2. **Repeat-work removal:** implement prepass/segment lookup ordering, cache producer sharing, unused framing-sample removal, and detection reuse. Measure cold and warm cases separately.
3. **Long-recording throughput:** detector work plans, combined scans, podcast overlap/chunking, and cache storage maintenance.
4. **Renderer consolidation:** Wizard artifact reuse, transform fusion, and transition/overlay pass fusion. Keep each change independently reviewable and preserve a tested fallback.

Do not parallelize the outer analysis-video loop as the first optimization: it deliberately refetches people so discoveries in earlier videos inform later identities (`AppStore.swift:1571`) and resets the run capture per video. Prefetching bounded local evidence for the next source is a safer later experiment. Preserve existing image/token budgets; any new persisted settings must decode older records and participate in settings copy/paste.

For each implementation, run focused unit/integration coverage and representative output comparisons, then the required project suite before delivery. Record baseline versus changed stage times, peak memory, bytes written, request/encode/detection counts, and UI latency. Accept a change only when the intended metric improves without unacceptable quality, identity, cancellation, or responsiveness regressions. No speedup multiplier is justified by this static review.
