# Video performance plan (independent review)

September 14, 2026. Reviewed at `c9eac1a` (Release 1.75, build 77) on this machine: Apple M4 Pro, 12 cores, 24 GB, macOS 27.0, Homebrew ffmpeg 8.1.2 with `videotoolbox` hwaccel, `h264_videotoolbox`, `scale_vt`, `scdet`, `zoompan`, `sendcmd`, `xfade`.

This is a second, independent pass; it does not build on the earlier Codex document. Method: I read the media pipeline sources in full myself (`FFmpeg.swift`, `ProcessRunner.swift`, `MediaWorkScheduler.swift`, `VideoDetectors.swift`, `Analyzer.swift`, `FramingService.swift`, `CenterStageService.swift`, `AreaFramer.swift`, `ThumbnailService.swift`, `SampledFrameCache.swift`, `RenderSegmentCache.swift`, `NormalizedAudioCache.swift`, `SourceIdentityCache.swift`, `MultitrackRenderer.swift`, `RenderEngine.swift`, `SmartSampling.swift`, `AnalysisImageBudget.swift`) and delegated three read-only audits (Builder UI and preview; Wizard, podcast, transcription and AI payloads; AppStore orchestration, SQLite, Drive resolver) whose claims I spot-checked against the source before including them. No code was changed, nothing was built, profiled or benchmarked. Every "expected" figure below is reasoning from the code, not a measurement, and is marked as such.

## Summary

The pipeline is already reasonably engineered: hardware encoding, a shared permit scheduler, disk caches for segments, thumbnails, probes, fingerprints, audio and detectors, and a Builder that only commits edits on drag end. What is left is structural, and it falls into six themes:

1. **Every video decode in ffmpeg is software.** Not one ffmpeg invocation passes `-hwaccel videotoolbox` (grep over `ClipBuilder/`), while the machine has a hardware decoder that is idle during segment composites, framing prepasses, detector scans and frame fallbacks.
2. **Cold analysis decodes the whole file more often than it needs to.** Two full-resolution detector passes, tracking that runs on both a parent scene and every child inside it, and frame grids that decode from the previous keyframe for each still.
3. **Renders with transitions or overlays encode every frame up to three times.** Segments are encoded, then every xfade-joined run is re-encoded, then the whole assembly is re-encoded for overlays that could not be fused because the transition clock was unknown.
4. **Center Stage work is never persisted at render time.** Each render and each 5-second exact preview re-tracks clips that have no stored path and re-exports the ones that do.
5. **Main-actor work per edit and per playback tick in the Builder.** Up to twelve JSON-encode-and-hash passes per edit, and a full document copy with fresh UUIDs on every 30 Hz playhead tick.
6. **The scheduler counts the wrong things.** Probes and decode-only ffmpeg jobs consume encode permits; AVFoundation exports consume none.

Recommended order, by expected impact per unit of effort: detector single pass (1), keyframe-snapped coarse grids (2), parent/child tracking dedupe plus a persistent framing cache (3, 6), transition segments with fused overlays (4), Builder main-actor work (5), permit classification (7), next-video warm-up (12), hardware decode (8), then the remaining items.

## Findings

Effort: S = one file, a day; M = a few files, a few days; L = a renderer-level change. Confidence is how sure I am the code does what I say and that the fix helps; it is not a measured speedup.

### 1. Cold detector scan: two full software decodes at native resolution

**Evidence.** `FFmpeg.detectors` (`ClipBuilder/Services/VideoDetectors.swift:49-63`) runs `blackdetect,freezedetect -an -f null` over the entire file, then calls `sceneChangeTimestamps` (`FFmpeg.swift:196-217`), a second full decode with `select='gt(scene,0.3)',showinfo`. The second pass has no `-an`, so audio is decoded and discarded too. Neither pass downscales before the detection filters, so `freezedetect`, `blackdetect` and the `scene` score all run on 4K frames. Both passes are charged to the `.encoding` budget (`ProcessRunner.swift:110-114`). `AppStore.cachedDetectors` (`AppStore.swift:3011-3017`) caches the result by fingerprint in SQLite, so this is a first-analysis and cache-invalidation cost, but it is paid for every new file before the first AI call, and `classifyLongRecording` (`Analyzer.swift:835`) can trigger a third scene pass when the cuts are not handed in.

**Change.** One ffmpeg process: `-hwaccel videotoolbox -an -i file -vf "scale=-2:360,split=2[a][b];[a]blackdetect=...,freezedetect=...[oa];[b]select='gt(scene,0.3)',showinfo[ob]"` mapped to two null outputs (or `scdet`, which is built for this and reports `lavfi.scd.time`). Keep the `mpdecimate` fallback for builds without `freezedetect`. Downscaling to 360p is what scene detectors are normally run on; `blackdetect` is a luma threshold and `freezedetect` a noise threshold, both insensitive to resolution at these settings, but the thresholds must be re-validated on fixtures because a downscale is a low-pass filter.

**Expected.** One decode instead of two, hardware instead of software, and detection filters on roughly one twentieth of the pixels. For a 30–60 minute 4K recording this is the difference between many minutes and about one; the decode becomes the only cost. Confidence high that it is much faster; medium that thresholds transfer unchanged.

**Verify.** Extend `VideoDetectorsTests` with a golden comparison of black/frozen ranges and cut lists between the old two-pass graph and the fused graph on a handful of fixtures (a fade-to-black intro, a frozen tail, a hard-cut recap, a no-audio file, a rotated phone clip). Count processes via `FFmpeg.commandCompleted`. Effort S. Risk low.

### 2. Coarse frame grids decode from the previous keyframe for every still

**Evidence.** All analysis stills go through `ThumbnailService.jpegFrames` (`ThumbnailService.swift:173-199`), which configures `AVAssetImageGenerator` with `requestedTimeToleranceBefore/After = 0.3 s` (`:241-242`). With a tolerance shorter than the GOP, the generator must decode from the preceding keyframe up to the requested time for each still. The classic pass asks for 30 stills 3 s apart (`Analyzer.frameTimestamps`, `Analyzer.swift:130-148`), the Smart Sampling map asks for one every 15 s per 5-minute window (`SmartSampling.coarseTimestamps`, `:78-89`), `classifyLongRecording` asks for 5, and `suggestTrim` for ~24 (`Analyzer.swift:1017`). With 1–2 s GOPs that is on the order of 15–60 decoded 4K frames per delivered still.

**Change.** Add a `snapToKeyframe` option to `jpegFrames` that sets both tolerances to `.positiveInfinity` (nearest keyframe) and returns the `actualTime` from each `AVAssetImageGenerator.Image` so the label carries the true timestamp. Use it for the classic grid, the coarse map, classification and trim. Keep exact seeking for dense breakdown windows, fight scoring, marker portraits, note references and portrait fit, where the exact instant matters. Keyframes are also the highest-quality frames in the stream, which does not hurt a model that is told frames are "sampled roughly every N seconds".

**Expected.** Roughly one decoded frame per still instead of tens, on the passes that dominate a new file's first minute. Confidence high for the mechanism; the drift of a still by up to half a GOP is a product decision, so ship it behind the same defaults key as `AnalysisImageLongestEdge` and compare tag output on a few known files.

**Verify.** Signpost `Frames` already exists (`ThumbnailService.swift:175`); add a decoded-frame counter via `AVAssetImageGenerator` result count and compare cold analysis wall time on the same file with and without snapping. Effort S. Risk low.

### 3. Center Stage tracks parent scenes and their children separately

**Evidence.** In `analyzeVisual` the Smart Sampling dense pass keeps the coarse scene and adds its actions inside it (`Analyzer.swift:1816-1838`), and both land in the same run (`setSceneParent`, `:1969-1980`). The portrait-fit loop (`:2015-2017`) and the Center Stage loop (`:2056-2112`) iterate `database.sceneRanges(runID:)`, which returns parents and children alike (`Database.swift:1967-1974`). So the tracker decodes and runs Vision over a 45 s parent, then again over each 5–10 s child inside it. `FramingService.detectFraming` (`FramingService.swift:80-120`) does the same over `fetchScenes(videoID:)` when the user runs the framing pass, and re-runs the three-sample Vision detection that `portraitFit` already ran on the same frames (`FramingService.swift:242-273` versus `Analyzer.swift:2196-2211`; `SampledFrameCache` shares the JPEGs, not the detections).

**Change.** Track the union of a video's scene ranges once (merge overlapping and touching ranges, exactly as `scoreFightAction` already merges its windows at `Analyzer.swift:1130-1149`), store one path per merged range, and derive each scene's path with `CenterStageService.slice` (`CenterStageService.swift:379-393`), which the renderer already uses to cut a scene path down to a clip. Cache human-detection results per (source fingerprint, timestamp, size) next to the JPEG so portrait fit, framing and the still-frame crop suggestion share them.

**Expected.** For breakdown-heavy fight footage roughly half the tracking work; for the framing pass on a re-analyzed video, no repeated Vision on the sample frames. A sliced parent path is also smoother at child boundaries than a fresh track that starts from the default box. Confidence high.

**Verify.** Existing `MultitrackRendererPlanningTests` cover slicing; add a test that a child range's stored path equals the parent's sliced path, and count `Vision` signposts per analysis on a fixture with a breakdown window. Effort M. Risk low, but scene-boundary smoothing changes slightly and should be eyeballed.

### 4. Transitions and overlays force whole-timeline re-encodes

**Evidence.** Segments are encoded once each (`MultitrackRenderer.compositeLayeredSegment`, `MultitrackRenderer.swift:1243-1452`). Assembly then re-encodes every run of xfade-joined clips in one `xfade`/`acrossfade` graph (`RenderEngine.xfadeAll`, `RenderEngine.swift:692-741`), while hard-cut runs are stream-copied (`concatPlain`, `:748-759`). Overlays are only fused into a segment if it lies before the first transition (`partitionOverlays`, `MultitrackRenderer.swift:1585`), because a crossfade shortens everything after it; the rest are burned in a third full re-encode (`addOverlays`, `:1650-1678`). A reel with transitions and a title therefore encodes every frame three times, and the segment cache can only ever save the first of the three.

**Change.** Make the transition a segment. For each xfade gap, render a short "join" segment whose inputs are the outgoing clip's last `d` seconds and the incoming clip's first `d` seconds (composited through the same per-placement filter chain, then `xfade`/`acrossfade`), and shorten the two neighbouring segments by `d`. `resolveRecipeGaps` (`RenderEngine.swift:580-677`) already does exactly this shape for recipe bridges: tail piece, bridge, head piece, all hard cut. With every gap a hard cut, assembly is always `concatPlain` (stream copy), the output clock is known before any encode, and `partitionOverlays` can fuse every overlay into its segment with exact local timing. Bumper spans are then plain arithmetic instead of the measure-after-join loop in `concatenateWithBumpers` (`:531-586`). Join segments get their own cache key (both clips' content plus the transition), so a caption edit re-encodes only the touched segment.

**Expected.** One encode per frame instead of up to three for any timeline with transitions or overlays; full segment-cache reuse on warm re-renders and exact previews; the overlay pass and the xfade pass disappear. Confidence high on the mechanism; this is how NLE smart-render works. Effort L. Risks: `acrossfade` needs the two audio tails at exactly `d`; the current `xfadeAll` clamps `d` to 40 % of the shorter clip (`RenderEngine.swift:707-710`) and the same clamp must be applied when planning segment lengths; every integration test in `MultitrackRenderTests` that counts encodes will change and must be re-baselined deliberately.

### 5. Builder: main-actor work per edit and per playback tick

**Evidence.** `BuilderWorkspacePreview.swift:105` calls `pruneBuilderPreviewCache()` on every model revision. That loops over up to 12 cached slices (`builderPreviewCacheLimit`, `AppStore.swift:357`) and recomputes `builderPreviewKey` for each (`AppStore.swift:4452-4512`): `MultitrackRenderer.windowed`, `resolveClips`, an `Evidence` struct holding the windowed document, resolved clips, scene facts and the whole `BrandProfile`, JSON-encoded with sorted keys and SHA-256 hashed, all on the main actor, before the next frame. `PreviewPane.body` (`PreviewPane.swift:14-60`) filters and sorts the whole video track for the bumper and the active clips on every playhead write, and calls `document.expandingOverlayBlocks()` on every tick; that copies the entire document and mints new `UUID`s for every expanded item (`TimelineModels.swift:108-137`), so the `ForEach` over overlays sees new identities 30 times a second during in-place playback (`PreviewPane.swift:588-600`) and rebuilds those views. Drags and trims themselves only commit on `.onEnded` (`TimelineView.swift:836-878`), and autosave is debounced and encoded off-main (`BuilderStore.swift:633-655`), so those are fine.

**Change.** Give `BuilderTimelineModel` a memoized "expanded overlays" value and an "active clips at t" query that invalidate on `revision`, with stable overlay identities (block uid plus item index, not a fresh UUID). For the preview cache, replace eager rekeying with lazy validation: record each slice's dependency set (clip uids in the window, scene ids, profile revision) when it is rendered, mark slices dirty from the edit that touched one of those, and compute the full key off the main actor only when a slice is about to be played or prefetched.

**Expected.** Removes the only synchronous JSON-encode-and-hash on the edit path and the per-tick document copy; playback and dragging during a cached preview stop competing with rendering for the main thread. Confidence high that the work exists; how many milliseconds it costs depends on document size and should be measured with Time Profiler on a 40-clip timeline before and after. Effort S–M. Risk low if stale slices are still invalidated conservatively.

### 6. Framing prepasses are never cached across renders

**Evidence.** `renderConfigured` computes a `prepassKey` per clip (`MultitrackRenderer.swift:1045-1060`) and dedupes framing jobs within one render (`:230-306`), but the outputs live in `framingScratch`, which is deleted at the end of the render (`:224-227`). A clip with a stored camera path still pays an AVFoundation export per render (`reframeClip(path:)`, `CenterStageService.swift:280-302`); a clip without one pays tracking plus export (`reframeClip(tuning:)`, `:227-271`) and the tracked path is thrown away. Exact preview is "the identical pipeline" (`:149-153`), so every 5-second preview of a Center Stage clip without a stored path re-tracks it.

**Change.** Persist prepass artifacts in `RenderSegmentCache` under the existing `prepassKey` (the key already covers source fingerprint, range, speed, path, area and tuning). When tracking runs at render time, write the resulting path back to a small path cache keyed by (fingerprint, source range, tuning, portraits digest) so the next render replays instead of tracking; scenes already store paths from the analysis pass and the Builder's `cameraPath` slice (`:717-723`) then applies. Look the segment cache up before the prepass: if every segment a prepass feeds is already cached, skip the prepass entirely (plan segments first, then run only the prepasses that a cache miss needs).

**Expected.** Warm exact previews and re-renders of Center Stage timelines skip tracking and export completely; cold previews track once per clip per session instead of once per press. Confidence high. Effort M. Risk: cache growth, bounded by the existing 2 GiB eviction; a prepass artifact must be evicted together with the segments that depend on it, or simply treated as an independent LRU entry (safe, since a missing prepass just re-runs).

### 7. The scheduler charges the wrong resources

**Evidence.** `ProcessRunner.run` takes an `.encoding` permit for every ffmpeg and ffprobe launch (`ProcessRunner.swift:110-114`): probes, the JPEG-frame fallback, loudness curves (`Analyzer.swift:2155-2161`), audio normalization (`NormalizedAudioCache.swift:27-28`) and detector scans all queue behind up to four segment encodes. Meanwhile `CenterStageService.export` (`CenterStageService.swift:771-847`) and the AVAssetExportSession in `reframeClip` hold no permit, so a render with four segment encodes plus four framing exports runs eight hardware encodes at once. Budgets are `encoding = min(4, cores/2)`, `decoding = cores/2`, `vision = 1` (`MediaWorkScheduler.swift:7-11`, `FFmpeg.swift:75`).

**Change.** Classify in `FFmpeg`/`ProcessRunner` by what the command does: ffprobe and `-f null` or `-frames:v 1` jobs take a decode permit (or a small dedicated probe budget); `-c:v copy` remuxes take none; everything else takes encode. Wrap the AVFoundation export in an encode permit. Then measure whether `encoding = 4` is even right on Apple Silicon: the media engine is shared, and two hardware encodes may finish sooner than four.

**Expected.** Probes, thumbnails and detector scans stop waiting behind renders; encode concurrency becomes what the budget says. Confidence high that the accounting is wrong; the throughput effect of retuning the budget must be measured. Effort S. Risk low.

### 8. No hardware decoding anywhere in ffmpeg

**Evidence.** No `-hwaccel` in the tree. Segment composites decode each source with libavcodec and scale with swscale (`compositeLayeredSegment`, `MultitrackRenderer.swift:1257-1350`), as do `extractClip` (`RenderEngine.swift:113-234`), `AreaFramer` (`AreaFramer.swift:59-99`), the detectors and the frame fallback. The ffmpeg build has `videotoolbox` hwaccel and `scale_vt`.

**Change.** Insert `-hwaccel videotoolbox` before each video `-i` in those graphs (ffmpeg falls back to software automatically when the codec or profile is unsupported, so no code path changes). Do not switch to `-hwaccel_output_format videotoolbox` plus `scale_vt`: the overlay and mask chains need system-memory frames, and the download would cancel the gain. Keep it behind a single switch in `FFmpeg` so it can be turned off per machine.

**Expected.** Lower CPU per decode, and a real wall-clock gain for 4K HEVC sources, which software-decode slowly; for 1080p H.264 the difference may be small. This one must be measured, not assumed: with four parallel jobs the hardware decoder and encoder share the media engine. Confidence medium. Effort S. Risk: colour range or pixel-format differences in the downloaded frames; compare output frames before enabling by default.

### 9. Tracking loop: serialized decode and Vision inside one actor

**Evidence.** `CenterStageService.trackPeople` (`CenterStageService.swift:410-547`) reads every frame with `copyNextSampleBuffer()` on the actor, skips frames until the next analysis instant, then awaits Vision under the single global Vision permit. Decode and Vision never overlap within a clip: the reader waits while Vision runs. The tracking loop and the export both run on the same actor instance, and `MultitrackRenderer` and `WizardEngine` each hold one instance (`MultitrackRenderer.swift:140`, `WizardEngine.swift:362`), so the four bounded-concurrency prepass jobs serialize their tracking and export on it. `copyNextSampleBuffer` is a blocking call on a cooperative-pool thread for the whole pass.

**Change.** Split the pass into a producer that decodes on its own thread (`Thread` or a serial `DispatchQueue`, not the cooperative pool) and hands scaled pixel buffers through a bounded channel, and a consumer that runs Vision; with the buffer, decode of frame n+1 overlaps Vision on frame n. Make `export` a free function or a separate actor so exports run alongside tracking. Then try `vision = 2`: Vision requests are thread-safe, and two in flight let the Neural Engine and CPU fallback overlap.

**Expected.** Up to about 2× on the tracking pass when decode and Vision are comparable (they are on 4K sources), plus real overlap of export and tracking across clips. Confidence medium; it depends on which half dominates. Effort M. Risk: memory, bounded by the channel depth; identical results, since frame selection does not change.

### 10. Wizard: bumpers and area clips multiply encode passes

**Evidence (from the Wizard audit, spot-checked).** A plain Wizard clip is one `extractClip` pass. Adding a bumper sends the already-normalized clips through `MultitrackRenderer` (`WizardEngine.swift:3092-3130`), which always composites through `-filter_complex` and re-encodes each of them. An area-layout clip pays `reframeClip` (AVFoundation export), then `AreaFramer.frame` (ffmpeg re-encode), then `extractClip` (ffmpeg re-encode), then `compositeAreas` for the block (`AreaFramer.swift:27-79`, `WizardEngine.swift:3354-3397`, `RenderEngine.swift:240-268`). Critique versions (up to three, `WizardEngine.swift:2371-2487`) start from a fresh scratch directory and re-extract every clip, even ones the re-plan kept.

**Change.** Give `MultitrackRenderer` a passthrough for a segment that is exactly one whole normalized intermediate with no captions, overlays, masks or effects (`-c copy` of the entire file is frame-exact; `-ss` on a copy is not, which is why it must be whole-file). Fuse `AreaFramer`'s crop/scale/pad into the `extractClip` graph so an area clip is one encode after its framing export. Key a per-run extraction cache on (source fingerprint, range, speed, treatment, overlays digest) so critique versions reuse untouched clips.

**Expected.** Bumper reels stop re-encoding their clips; area clips drop from four passes to two; critique revisions cost only the clips that changed. Confidence high. Effort M. Risk low.

### 11. Cache hygiene

- `RenderSegmentCache.restore` copies the artifact and then runs `evict`, which lists and sorts the whole cache directory, on every hit (`RenderSegmentCache.swift:31-41`, `85-100`); `store` does the same. On APFS the copy is a clone and cheap; the directory scan is the waste. Track total bytes in memory and sweep on `store` only, or every N hits. Effort S.
- `RenderSegmentKey` includes the absolute `start` (`:105-116`) and `ResolvedClip.startTime`/`originalStart`, so moving a clip along the timeline invalidates identical pixels. Key on segment-local content (source ranges, order, effects, captions and overlays already local) and keep `start` out. Effort S. Confidence medium: check that nothing in the filter graph depends on absolute time (fades use `originalStart` relative to the segment, so they must stay in the key as local offsets).
- `SourceIdentityCache.fingerprint` (`SourceIdentityCache.swift:30-56`) holds one `NSLock` around a 2 MB read and rewrites the entire identities JSON after every new file; a first scan of a large folder is O(n²) bytes of JSON and serializes every caller. Batch the index write (debounce, or write once at the end of `scanSourceFolder`) and release the lock during the hash. This is also `docs/TODO.md` item 18. Effort S.
- `NormalizedAudioCache.audio` (`NormalizedAudioCache.swift:15-46`) and `Analyzer.cachedLoudnessCurve` (`Analyzer.swift:2137-2149`) have no in-flight dedupe, so transcription, diarization and analysis can all launch the same ffmpeg extraction at once; `ProbeCache` (`FFmpeg.swift:235-247`) shows the pattern to reuse. Effort S.
- `Analyzer.imageTokens` decodes every JPEG with `NSBitmapImageRep` just to read its size (`Analyzer.swift:98-104`), and the budget fit runs twice per call (`extractFrames` at `:294-303`, then `callThinningFrames` at `:189-192`). Read dimensions with `CGImageSourceCopyPropertiesAtIndex` and fit once. Small per call, but it runs for every coarse and dense window. Effort S.
- `PodcastVisualAnalyzer` and `ReelCritic` await Vision one frame at a time in a loop (`PodcastAnalysisService.swift:444-456`, `ReelCritic.swift:72-77`) where `detectContentBox` already uses a task group (`RenderEngine.swift:288-301`). Effort S.

### 12. Overlap the next video's local evidence with the current video's remote wait

**Evidence.** An analysis run processes its videos strictly one after another (`AppStore.swift:1538-1698`; the pipeline comment at `:1768-1773` says so on purpose). Per video, the local work that runs before the first AI call is the detector scan (`cachedDetectors`, `:1551`), the frame grid, and, for long recordings, classification; loudness is already overlapped with the AI call via `async let` (`Analyzer.swift:1604`), and transcription's normalized audio extraction runs after it (`TranscriptionService.swift:203`). Every one of those local steps is cache-backed and idempotent (detectors in SQLite by fingerprint, loudness and identities in `source-evidence`, normalized audio in `NormalizedAudioCache`), and none depends on the AI response for the previous video; only people identities do, which is why the loop refetches people per video.

**Change.** Keep the loop sequential for AI calls and people, but start a bounded "warm-up" task for video i+1 when video i's first AI call is issued: detectors, loudness, normalized audio and the keyframe-snapped classic grid. Bound it to one video ahead and run it at background priority under the existing permits so it cannot starve the current video's dense windows.

**Expected.** For multi-video runs the local cold cost of each file after the first hides behind the previous file's remote wait, which is usually the longest stage. Confidence high; the caches make it safe. Effort S–M. Risk: disk pressure from one extra normalized WAV in flight; acceptable.

### 13. Orchestration, database and Drive details

Spot-checked from the orchestration audit:

- **Framing pass writes are unbatched.** `FramingService.detectFraming` issues, per scene, `setSceneCenterStagePath` (two statements, `Database.swift:2366-2371`), `removeSceneTags` and one `addSceneTag` per framed person (`FramingService.swift:109-117`), each an autocommit on a WAL database with `synchronous=NORMAL` (`Database.swift:628-637`). `saveAnalysis` deliberately wraps its hundreds of rows in one transaction (`Database.swift:2467-2532`). Wrap the framing loop's writes per video the same way, and likewise the per-scene `addSceneTag`/`setSceneCropX`/`setSceneCenterStagePath` calls in the portrait-fit and Center Stage loops of `analyzeVisual` (`Analyzer.swift:2017-2041`, `2078-2112`). Effort S.
- **No prepared-statement reuse.** `SQLiteConnection.execute`/`query` prepare and finalize every call (`SQLite.swift:97-127`). Hot statements (`addSceneTag`, `transcriptSegments` per segment render, `driveMedia(path:)`) would benefit from a small statement cache keyed by SQL text. Effort S, low priority; the batching above matters more.
- **Drive lease per frame batch.** `DriveLocalAsset.make` (`DriveLocalAsset.swift:23-28`) hops to the `DriveMediaResolver` actor, stats the file (`DriveMediaResolver.swift:17-24`) and creates a fresh `AVURLAsset` for every `jpegFrames`/`jpegFrame`/`grayscaleFrame` call; release is another actor hop from `deinit`. For local files this is latency, not I/O; dozens of calls per video. Reuse one asset per (source, run) in `SampledFrameCache`, and keep a negative cache of paths known not to be Drive media. Effort S.
- **Folder watcher rescans.** Every debounced folder event walks the whole source tree and stats every file (`FolderWatcher.swift:17-38`, `Analyzer.swift:29-53`); unchanged files short-circuit on size and mtime, so the remaining cost is the walk plus the index rewrite in item 11. Fine at hundreds of files; revisit with the index batching.
- **Duplicate finder is O(n²).** `LocalDuplicates.groups` scans every existing group per signature and looks videos up by linear search (`LocalDuplicates.swift:32-47`, `62`). On demand only; index videos by id and bucket by (duration, size) before pairwise hashing when the library grows. Effort S.
- **Loudness decodes the source audio separately from the normalized WAV.** `loudnessCurve` runs ffmpeg on the original file (`Analyzer.swift:2155-2161`) while transcription and podcast analysis share the 16 kHz mono WAV (`NormalizedAudioCache.swift`). RMS at 8 kHz would be identical from the WAV; prefer it when present. Effort S.

## What to measure first

Signposts already cover source scan, frames, Vision, framing export, segment encode, assembly, overlay burn and thumbnails (`PerfSignpost.swift`, call sites throughout). Before changing anything, capture three Instruments traces on a Release build with `-ClipBuilderDataFolder` pointing at scratch data:

1. A cold analysis of a 30–60 minute wide fight recording with Smart Sampling, people and Center Stage paths on. Count ffmpeg launches (`FFmpeg.commandCompleted`), decoded frames, `Vision` intervals, and wall time per stage.
2. A Builder render of a 40-clip timeline with captions, two xfades, one title overlay and a Center Stage clip: once cold, once unchanged, once after a caption edit. Count segment encodes and passes.
3. Twenty seconds of in-place preview playback while dragging a clip, with Time Profiler on the main thread.

Those three traces rank items 1–9 against each other on real material; the order above is my expectation, not a measurement. Keep the traces as the before/after baseline for every change.

## Sequencing and gates

1. **Week one, low risk:** items 1, 2, 7, the write batching in 13, and the small hygiene items in 11. Each is a contained change with an existing test file to extend (`VideoDetectorsTests`, `RenderSegmentCacheTests`, `SourceIdentityCacheTests`, `AnalyzerStaticTests`).
2. **Analysis throughput:** items 3, 6, 9 and 12. Gate: identical scene paths on fixtures (or sliced-parent paths where intended), Vision call counts down, no change in framed-people tags, and the run log still shows one video's AI calls at a time.
3. **Render architecture:** item 4, then 10, then 8 as a measured experiment. Gate: frame-level comparison of old and new output on `MultitrackRenderTests` fixtures (PSNR over decoded frames, not byte equality), duration and A/V sync checks, and re-baselined encode counts.
4. **Builder responsiveness:** item 5. Gate: no JSON encoding on the main thread in a Time Profiler trace during editing; stale slices still invalidated.

Do not run items in parallel with each other in one branch: 4 changes the encode counts that 6 and 10 are measured against.

## Where this differs from the earlier document

The Codex plan and this one agree on: scheduler and export-permit gaps, looking the segment cache up before framing work, persistent prepass caching, Wizard artifact reuse, and the per-edit preview-key work. This review adds items it did not have, in order of importance: fusing transitions into cacheable join segments (which removes the reason overlays could not be fused, rather than treating it as a hazard), the parent/child double tracking, keyframe-snapped coarse grids, the absence of hardware decoding, the per-tick document copy and UUID churn in the preview pane, the Vision budget of one, and the Wizard bumper passthrough. It also deprioritizes two of its items: podcast stage overlap (the frame batch is bounded at two frames per turn and the cheap fix is a task group) and building a large measurement harness before touching anything (three traces are enough to rank the work).
