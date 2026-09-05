# Peace Grappler implementation review handoff

This document records the implementation work performed against
[`docs/PG-Implementation-Plan.md`](../PG-Implementation-Plan.md). It is intended for a second model or engineer to compare the code with the original requirements, identify gaps, and decide what should be revised before release.

## Scope and status language

- **Implemented** means the requested user-visible path exists and is connected to persistence/rendering where applicable.
- **Partial fidelity** means a usable first version exists, but some part of the exact requirement is heuristic, prompt-driven, or narrower than requested.
- **Not implemented by design** means the plan explicitly deferred or delayed the feature.

The current implementation covers items 1–11 and 13–17. Several of those should be treated as partial-fidelity implementations rather than unquestioned closure; those limitations are called out below.

## Executive summary

The change adds:

- Per-profile and per-timeline output canvases and encode quality.
- Explicit cut cadence and pace-curve controls.
- Transcript feature persistence, speaker hints, topic ranges, cleanup proposals, translation tracks, and SRT export.
- An optional cut-review checkpoint before Wizard rendering.
- A built-in lower-third overlay for Builder and Wizard use.
- B-roll marking, image subject tagging, image search, and edit-time owned-media suggestions.
- Story, square-feed, 4:5-feed, and carousel-still exports.
- Queryable generated-video traits and editing-performance reports.
- Athlete, hook, layout, cadence, pace, and cut-target comparisons.
- Opt-in learned profile defaults.
- Four CSV report exports.

The explicitly delayed long-form podcast editor and posting scheduler were not added. Deferred third-party/platform integrations were also not added.

## Requirement-by-requirement comparison

### 1. Output sizes and aspect ratios

**Status: Implemented, with a performance tradeoff to review.**

Delivered:

- Added `RenderSettings`, `RenderPreset`, and `EncodeQuality`.
- Presets include:
  - 9:16 1080p: 1080×1920
  - 9:16 4K: 2160×3840
  - 16:9 1080p: 1920×1080
  - 16:9 4K: 3840×2160
  - 1:1: 1080×1080
  - 4:5: 1080×1350
  - Custom dimensions, clamped to even H.264-compatible values
- Added High, Balanced, Compact, and custom-CRF quality settings.
- Profile defaults feed Wizard runs; Builder documents keep their own copy.
- Timeline JSON persists output and pacing settings with backward-compatible decode defaults.
- Render dimensions now flow through `RenderContext` task-local state so concurrent renders do not share mutable globals.
- Updated the main render engine, multitrack renderer, Center Stage default size, area framing, overlays, brand graphics, caption rendering, and Builder preview sizing.
- Brand artwork scales from the old 1080×1920 design coordinates into the selected output canvas.

Primary files:

- `ClipBuilder/Data/RenderSettings.swift`
- `ClipBuilder/Data/TimelineModels.swift`
- `ClipBuilder/Data/BrandProfile.swift`
- `ClipBuilder/Views/RenderSettingsControls.swift`
- `ClipBuilder/Services/RenderEngine.swift`
- `ClipBuilder/Services/MultitrackRenderer.swift`
- `ClipBuilder/Services/BrandRenderer.swift`
- `ClipBuilder/Services/CenterStageService.swift`
- `ClipBuilder/Services/TextOverlayRenderer.swift`
- `ClipBuilder/Views/Builder/PreviewPane.swift`

Review caveat:

- `FFmpeg.videoEncodeArgs` now uses `libx264` for configured renders so CRF has consistent semantics. This bypasses the prior VideoToolbox hardware path and may materially slow exports. A reviewer should decide whether preset quality levels should use resolution-aware VideoToolbox bitrates while only custom CRF uses x264.
- Landscape/square brand-card composition should be visually inspected. The output dimensions are correct, but the original brand layout was designed around portrait coordinates.

### 2. Transcript pipeline upgrades

**Status: Partial fidelity.**

Delivered:

- Apple `SpeechAnalyzer`/`SpeechTranscriber` remains the on-device transcription source.
- Added a persisted shared transcript-feature model with:
  - speech
  - silence
  - filler
  - noise enum support
  - speaker key
  - normalized speech-density energy
- Transcription automatically enriches both newly generated and cached transcripts.
- Speaker hints are grounded in overlapping analyzed scenes carrying existing `person:<key>` tags.
- When no visual identity hint exists, the analyzer uses a conversational fallback that rotates known speakers after longer pauses.

Primary files:

- `ClipBuilder/Data/TranscriptFeatureSegment.swift`
- `ClipBuilder/Services/TranscriptFeatureAnalyzer.swift`
- `ClipBuilder/Services/TranscriptionService.swift`
- `ClipBuilder/Data/Database.swift`

Review caveats:

- This is **not true acoustic speaker diarization**. It uses visual scene/person tags first and a pause-based speaker fallback. Audio-only podcasts or multi-speaker shots may receive incorrect speaker labels.
- Energy is word density, not an audio waveform loudness/energy measurement.
- The data model supports noise, but robust off-mic-noise detection is not currently implemented.

### 3. Cut cadence and pace curve

**Status: Implemented as an explicit planning contract; partial deterministic enforcement.**

Delivered:

- Cadence choices: Automatic, every 2 seconds, every 3 seconds, and a 2–4 second mix.
- Pace curves: Steady, Accelerate, Decelerate, and Build Then Drop.
- Explicit cadence is injected as a hard Wizard instruction and overrides account benchmarks, learned defaults, and reference templates.
- Builder timeline ruler renders cadence markers using the selected curve.
- Settings, Wizard, and Builder expose the controls.

Primary files:

- `ClipBuilder/Data/EditPacing.swift`
- `ClipBuilder/Views/EditPacingControls.swift`
- `ClipBuilder/Services/WizardEngine.swift`
- `ClipBuilder/Views/Builder/TimelineView.swift`

Review caveat:

- Cadence and pace are enforced through the planner prompt. There is no deterministic post-plan validator that rewrites or rejects every clip that falls outside the requested interval/curve.

### 4. Lower thirds

**Status: Implemented according to the answer that it should remain an ordinary out-of-box overlay.**

Delivered:

- Added a clean built-in lower-third composition with name, role, optional logo, left/right positioning, and slide animation.
- It uses the existing `OverlayComposition`, `TextOverlayItem`, and `ImageOverlayItem` types rather than introducing a new first-class overlay model.
- Builder Add → Overlay exposes a blank option and named-person options.
- Wizard interview and podcast recipes automatically add lower thirds on a named person's first eligible appearance.
- Render engine recognizes left/right slide animations.

Primary files:

- `ClipBuilder/Data/LowerThirdOverlay.swift`
- `ClipBuilder/Views/Builder/BuilderAddMenu.swift`
- `ClipBuilder/Services/WizardEngine.swift`
- `ClipBuilder/Services/RenderEngine.swift`

Review caveat:

- Wizard auto-placement depends on scene person tags. A clip that already has planner text is skipped rather than layering both pieces of text.

### 5. Proposed-cut review

**Status: Implemented.**

Delivered:

- Added an optional review step after Wizard planning and before rendering.
- Each planned clip displays a source thumbnail, reason, editable in/out points, and include toggle.
- Final values are clamped to source-scene bounds and transitions are normalized before continuation.
- Users can either render the accepted cuts or open the reviewed plan in Builder.
- Podcast recipe enables review by default; leaving the recipe turns it back off.

Primary files:

- `ClipBuilder/Data/ProposedCutReviewRequest.swift`
- `ClipBuilder/Views/ProposedCutsSheet.swift`
- `ClipBuilder/App/AppStore.swift`
- `ClipBuilder/ContentView.swift`

### 6. Topic separation for podcasts

**Status: Partial fidelity.**

Delivered:

- Added persisted titled `TopicRange` rows.
- On-device segmentation uses long pauses, new questions after an established span, speaker changes, and a maximum topic span.
- Transcript Tools displays saved topics with titles, time ranges, and summaries.
- Added a “Podcast topic clip” Wizard recipe.
- The Wizard receives saved topic ranges and is instructed to build one self-contained output around one topic without leaving its video/time range.

Primary files:

- `ClipBuilder/Data/TopicRange.swift`
- `ClipBuilder/Services/TopicSegmenter.swift`
- `ClipBuilder/Views/TranscriptToolsSheet.swift`
- `ClipBuilder/Services/WizardEngine.swift`

Review caveats:

- Subject-shift detection is heuristic; there is no semantic embedding or language-model topic classifier in this on-device pass.
- The Wizard creates one topic clip per run. There is no batch command that automatically generates one separate output for every saved topic.
- Topics are stored in their own scene-like table, not inserted into the primary `scenes` table.

### 7. Dead-air and garbage-cut suggestions

**Status: Partial fidelity.**

Delivered:

- Silence longer than the configurable threshold creates a cleanup proposal.
- Filler-only transcript runs create cleanup proposals.
- Defaults are 1.5 seconds for dead air and 2 seconds for filler runs.
- Both values are adjustable in Settings.
- Each proposal has editable start/end values and Pending/Accept/Reject decisions persisted in SQLite.
- Accepted proposals are passed to podcast Wizard planning as hard exclusion ranges.

Primary files:

- `ClipBuilder/Data/EditProposal.swift`
- `ClipBuilder/Services/TranscriptFeatureAnalyzer.swift`
- `ClipBuilder/Views/TranscriptToolsSheet.swift`
- `ClipBuilder/Data/AppSettings.swift`
- `ClipBuilder/Views/SettingsView.swift`

Review caveats:

- False-start detection and off-mic-noise detection are not implemented beyond enum/schema placeholders.
- Accepted cleanup cuts are enforced by the Wizard prompt, not a deterministic media-range subtraction pass.
- The transcript cleanup list and planned-cut sheet share the same interaction concepts, but not one reusable SwiftUI component.

### 8. Caption translation

**Status: Implemented.**

Delivered:

- Transcript Tools offers Brazilian Portuguese (`pt-BR`) and United States English (`en-US`).
- Uses Apple's `TranslationSession` on device when available.
- Falls back to the configured routed AI provider per segment if Apple translation fails.
- Stores translated captions in the existing transcripts table as translation tracks.
- Profile default language list now defaults to `en-US` and `pt-BR` for new or previously unspecified profiles.
- Wizard and Builder caption rendering can request the chosen/default translation track and fall back to original transcript text.
- Sidecar SRT export is available.

Primary files:

- `ClipBuilder/Views/TranscriptToolsSheet.swift`
- `ClipBuilder/Data/BrandProfile.swift`
- `ClipBuilder/Data/Database.swift`
- `ClipBuilder/Services/WizardEngine.swift`
- `ClipBuilder/Services/MultitrackRenderer.swift`

Review caveat:

- AI fallback translates each row separately, so cross-segment terminology/context can be less consistent than a batched translation.

### 9. B-roll tagging and image library by subject

**Status: Implemented.**

Delivered:

- Scene rows expose a manual B-roll toggle in Scenes menus/context menus.
- Default analysis tags now include `b-roll`, `cutaway`, and `establishing-shot` so the existing visual analysis pass can label video scenes.
- Added persisted metadata for owned image assets: subjects, tags, B-roll flag, provider, and model.
- Images can be tagged one at a time or in a visible batch with the existing image-capable AI analysis route.
- Known people are supplied to image tagging for fighter/person matching.
- Image grid supports filename, subject, event, and tag filtering.
- Added “Ask the Image Library,” which uses the configured search model to rank stored image metadata for a natural-language request.

Primary files:

- `ClipBuilder/Data/LibraryAssetMetadata.swift`
- `ClipBuilder/Views/AssetBrowserView.swift`
- `ClipBuilder/Views/ImageLibrarySearchSheet.swift`
- `ClipBuilder/Views/ScenesView.swift`
- `ClipBuilder/App/AppStore.swift`
- `ClipBuilder/Data/Models.swift`

Review caveat:

- Ask Images searches previously generated metadata rather than sending every image to the model on every query. Untagged images therefore cannot match semantically until they are analyzed.

### 10. Photo and B-roll suggestions inside an edit

**Status: Partial fidelity.**

Delivered:

- Builder can calculate suggestions from the people and tags in current timeline clips.
- Matching owned photos can be accepted as image overlays at the relevant timeline time.
- Matching B-roll scenes can be accepted as cutaway clips.
- The cut-review sheet can open the accepted Wizard plan in Builder, where the same suggestions become available.
- Gap-report inventory includes tagged-photo counts, B-roll counts, untagged-photo counts, and explicit instructions to recommend owned media or missing coverage.

Primary files:

- `ClipBuilder/Data/MediaSuggestion.swift`
- `ClipBuilder/Services/MediaSuggestionService.swift`
- `ClipBuilder/Views/Builder/MediaSuggestionsSheet.swift`
- `ClipBuilder/Views/Builder/BuilderView.swift`
- `ClipBuilder/App/AppStore.swift`

Review caveats:

- Photo suggestions are not embedded directly in the Wizard's planned-cut review and are not automatically composited by a direct Wizard render. The supported path is Review → Edit Accepted Cuts in Builder → Photo & B-roll Suggestions.
- Matching is tag/subject intersection, not an embedding-based relevance score.

### 11. Instagram formats beyond reels

**Status: Implemented for export-only, with a best-frame limitation.**

Delivered:

- Generated videos can be exported as:
  - Story, 9:16
  - Square feed video, 1:1
  - Portrait feed video, 4:5
  - Five-slide square JPEG carousel
- All paths are local file exports; no carousel/story publishing was added.

Primary files:

- `ClipBuilder/Services/SocialFormatExporter.swift`
- `ClipBuilder/Views/SocialFormatExportSheet.swift`
- `ClipBuilder/Views/LibraryView.swift`

Review caveat:

- Carousel frames are evenly distributed through the reel from 5% to 95%. The UI says “best-frame stills,” but no visual-quality/highlight ranking currently chooses those frames.

### 12. Long-form podcast editor

**Status: Not implemented by design.**

The plan says “DELAY THIS feature. do not implement.” No multi-camera ingest, waveform synchronization, automatic camera switching, episode project, or chapter-marked long-form render was added.

### 13. Record edit traits on every published reel

**Status: Implemented.**

Delivered traits:

- Output width and height
- Calculated cuts per minute
- Pace curve
- Inferred hook type and hook length
- Featured person keys
- Screen/layout seconds
- Cut-target counts for fighter, B-roll, photo, text, and graphic

Traits are written when Wizard or Builder renders a generated video. If an older timeline-backed generated video has no traits when it is published, the publish path backfills them.

Primary files:

- `ClipBuilder/Data/PublishedEditTraits.swift`
- `ClipBuilder/Data/Database.swift`
- `ClipBuilder/Services/WizardEngine.swift`
- `ClipBuilder/Services/MultitrackRenderer.swift`
- `ClipBuilder/App/AppStore.swift`

Review caveat:

- Hook type is inferred from plan rationale/reason text, not stored from a dedicated explicit hook-type planner field.
- A legacy generated video whose timeline cannot decode cannot be backfilled accurately.

### 14. Athlete return report

**Status: Implemented with approximate follower attribution.**

Delivered:

- Per-person appearance count.
- Per-appearance followers, views, reach, watch time, shares, saves, and comments.
- Ranking picker for each metric.
- Top athlete performance is injected into Wizard planning guidance and the content gap report.

Primary files:

- `ClipBuilder/Data/EditingPerformanceInsights.swift`
- `ClipBuilder/Services/PerformanceAnalytics.swift`
- `ClipBuilder/Views/Instagram/EditingPerformanceView.swift`
- `ClipBuilder/Services/WizardEngine.swift`
- `ClipBuilder/App/AppStore.swift`

Review caveat:

- Instagram does not provide follower gain per reel. The implementation allocates the report window's total new followers across linked reels by each reel's share of reach, then normalizes per appearance. This is an estimate, not direct attribution.

### 15. Hook and screen-type performance

**Status: Implemented, with inferred/limited dimensions.**

Delivered groupings:

- Hook type
- Hook-length band
- Dominant screen/layout
- Cadence band
- Pace curve
- Athlete
- Cut-target type

Each grouping reports reel count, average watch time, and average reach. Suggested hook, layout, and cadence values are selected and supplied to the Wizard.

Primary files:

- `ClipBuilder/Services/PerformanceAnalytics.swift`
- `ClipBuilder/Views/Instagram/EditingPerformanceView.swift`
- `ClipBuilder/Data/PublishedEditTraits.swift`

Review caveats:

- There is no separately persisted subject taxonomy in generated-video traits. Athlete and cut-target groupings cover part of the requested “athlete and subject” analysis, but subject-level hook ranking is incomplete.
- Results are observational correlations with no minimum sample threshold or confidence interval.
- True viewer drop-off remains unavailable, as the original plan noted.

### 16. Feed winning timing and screen type into standard setup

**Status: Implemented, with prompt-based hook/layout application.**

Delivered:

- Per-profile opt-in toggle.
- Visible “learned from your results” label.
- Winning cadence updates the profile's concrete default cadence choice.
- Winning hook and layout are stored on the profile and injected into Wizard planning guidance.
- Explicit user cadence/output choices still take precedence.

Primary files:

- `ClipBuilder/Data/BrandProfile.swift`
- `ClipBuilder/App/AppStore.swift`
- `ClipBuilder/Views/Instagram/EditingPerformanceView.swift`
- `ClipBuilder/Services/WizardEngine.swift`

Review caveat:

- Hook and layout preferences steer the planner through text rather than selecting a concrete Wizard control/layout automatically. Cadence is the only winner directly mapped into a concrete profile setting.

### 17. Spreadsheet export

**Status: Implemented as CSV, matching the plan answer.**

The Reports editing-performance page exports a `ClipBuilder-Reports` directory containing:

- `reels.csv`: per-reel traits and linked metrics
- `account-weekly.csv`: weekly posts and engagement totals
- `athlete-rankings.csv`: normalized athlete-return table
- `editing-rankings.csv`: hook/layout/cadence/pace/athlete/cut-target patterns

Primary files:

- `ClipBuilder/Services/ReportCSVExporter.swift`
- `ClipBuilder/Views/Instagram/EditingPerformanceView.swift`

### 18. Posting schedule with approval

**Status: Not implemented by design.**

The plan says “DELAY THIS FEATURE DO NOT implement.” No queue, calendar, approval scheduler, digest, or timed publisher was added.

## Explicit deferred scope that remains absent

The following were not implemented:

- Windsor integration
- HypeAuditor integration
- OpusClip integration
- TikTok output, publishing, or metrics
- YouTube publishing or metrics
- Cross-platform “where to post” recommendations
- Instagram per-second retention/drop-off analysis or manual retention import
- Long-form podcast editor
- Posting scheduler

## Persistence changes

`Database.schema` now always creates these tables with `CREATE TABLE IF NOT EXISTS`, including for already version-stamped databases:

### `transcript_features`

- video foreign key
- start/end time
- text
- speaker key
- energy
- feature kind

### `topic_ranges`

- video foreign key
- title
- start/end time
- summary
- speaker keys JSON

### `edit_proposals`

- optional video foreign key
- proposal kind
- start/end time
- reason
- decision

### `library_asset_metadata`

- asset path primary key
- asset kind
- B-roll flag
- subjects JSON
- tags JSON
- provider/model provenance
- analysis timestamp

### `generated_video_traits`

- generated-video foreign key
- output dimensions
- cadence
- pace curve
- hook type/length
- people JSON
- screen seconds JSON
- cut targets JSON

The schema script runs on every database open before version-gated column migrations, so these new tables do not depend on incrementing `schemaVersion`.

## Main user flows added

### Podcast short-form flow

1. Transcribe a video with Apple Speech.
2. Open Transcript → Topics, Cuts & Translation.
3. Analyze the transcript to persist speech/silence/filler features, topics, and cleanup proposals.
4. Accept, reject, or shorten cleanup ranges.
5. Optionally translate to `pt-BR`/`en-US` or export SRT.
6. Choose “Podcast topic clip” in Wizard.
7. Wizard loads topic ranges and accepted cleanup exclusions.
8. Review proposed clips before rendering.
9. Render directly or open accepted clips in Builder for media suggestions and further edits.

### Owned-media flow

1. Add images to the Images library.
2. Run AI subject/tag analysis per image or for visible images.
3. Search by name/subject/tag or use Ask Images.
4. Mark video scenes or images as B-roll where appropriate.
5. Open a Wizard plan in Builder or construct a Builder timeline.
6. Open Photo & B-roll Suggestions.
7. Accept matching photos as overlays or B-roll scenes as timeline clips.

### Results-learning flow

1. Generate/render a video; traits are persisted.
2. Publish/link it to Instagram insights.
3. Open Reports → Editing.
4. Review athlete return and editing-pattern rankings.
5. Optionally enable learned defaults for the active profile.
6. Export the tables as CSV.

## Validation performed

### Build

The following Debug build completed successfully after the final Swift formatting pass:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project "Clip Builder.xcodeproj" \
  -scheme MyApp \
  -configuration Debug \
  -derivedDataPath /private/tmp/clipbuilder-pg-build \
  -destination "generic/platform=macOS" \
  CODE_SIGNING_ALLOWED=NO build
```

Result: `BUILD SUCCEEDED`.

### Tests

`./scripts/test.sh` completed successfully before the final documentation-only change. It ran the full `ClipBuilderTests` target, including FFmpeg-backed render integration tests available on the machine.

Observed passing coverage included:

- Database fresh-schema and legacy migration tests
- Settings/profile compatibility tests
- Timeline-document compatibility tests
- Wizard validation and timeline tests
- Fake-AI planning/persistence tests
- Multitrack planning and render tests
- Render engine extraction, normalization, music, and every-transition concatenation tests
- New Peace Grappler feature tests

New focused tests in `ClipBuilderTests/Services/PGFeatureTests.swift` cover:

- Output preset dimensions and even custom dimensions
- Steady and accelerating cadence markers
- Silence/filler proposals and speaker-hint use
- Topic boundaries and source ranges

A later user-requested rerun of `./scripts/test.sh` was manually aborted almost immediately; it did not report a regression and should not be confused with the earlier completed passing run.

### Hygiene

- `git diff --check` passed.
- New Swift files were run through Xcode's `swift-format` with four-space indentation.
- No commit or push was performed by the implementing model.

## Known Xcode warnings observed

The test/build output contains existing macOS 26/Swift concurrency warnings, notably:

- Deprecated `AVMutableVideoComposition*` APIs.
- Main-actor isolation warnings in existing pipeline/preview code.
- `MoveCommandDirection` switches without `@unknown default`.
- A concurrently executing closure captures mutable `brandOverlays` in `WizardEngine`.

They did not prevent the Debug build or test suite from passing, but a reviewer should determine whether the project's Swift language mode will promote them to errors later.

## Recommended review order

1. **Correctness and migrations:** open an existing profile database and verify all five new tables are created and populated.
2. **Render matrix:** render a short fixture in every preset, especially 16:9 and 4K, with captions, text, image overlay, lower third, brand headline, and outro.
3. **Encoder decision:** benchmark x264 CRF against the former VideoToolbox path and choose an acceptable quality/performance mapping.
4. **Podcast accuracy:** test audio-only and multi-speaker footage; decide whether true acoustic diarization is required.
5. **Cleanup safety:** replace prompt-only accepted-cut exclusion with deterministic range subtraction if frame-accurate guarantees are required.
6. **Topic batching:** decide whether “one clip per topic” requires a one-click batch generator rather than one topic output per Wizard run.
7. **Media suggestions:** decide whether photo choices must appear directly inside Wizard cut review/direct rendering.
8. **Carousel quality:** replace evenly spaced frames with scene-score/highlight/blur-aware frame selection if “best frames” is a hard requirement.
9. **Analytics validity:** add sample thresholds and clarify estimated follower attribution in UI copy.
10. **Subject analytics:** persist explicit subject tags in generated traits if item 15 requires true subject-level comparisons.

## Change-set boundary note

At the time this handoff was written, `docs/ui-projects/` files were also present in the staged worktree. Those UI-project artifacts were not created as part of the Peace Grappler implementation described above and should be reviewed as a separate change set.
