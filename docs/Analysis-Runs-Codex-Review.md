# Analysis Runs: Codex review

Date: October 12, 2026. Reviewer: Codex (gpt-6-astra), read-only, of docs/Analysis-Runs-Plan.md as drafted that day.

## Verdict

**Revise before implementation.** The per-layer selection model is useful, but Phase A is not independently safe as written. Default source discovery must use active batches; historical scene resolution must remain independent of that default.

The review found three incorrect assumptions: `speech_seconds` measures processing time, saved takes are not batch-stable merely because they contain scene IDs, and existing sync does not implement pinned-over-automatic conflict resolution.

This was a static, read-only review. No files—including `HANDOFF.md`—were modified; no builds or tests were run. Predicted consequences below follow from the cited code; unvalidated quality assumptions are identified as hypotheses.

## Blocking issues

1. **Separate discovery from historical resolution before filtering `fetchScenes`.** Saved-take rendering fetches the project scene list and rejects missing IDs. Filtering that list would reject still-existing scenes from inactive batches. See [WizardEngine.swift:2593](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/WizardEngine.swift:2593) and [WizardEngine.swift:2702](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/WizardEngine.swift:2702).

2. **Replace the transcript coverage denominator.** `transcripts.seconds` and `videos.speech_seconds` store elapsed transcription processing time. Dividing transcript duration by this value measures neither completeness nor speech coverage. [Database+Transcripts.swift:79](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Transcripts.swift:79), [TranscriptionService.swift:213](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TranscriptionService.swift:213).

3. **Specify and implement pointer conflict semantics.** Incoming sync rows with pending local writes are skipped; otherwise portable columns are replaced together. No pin precedence exists. A newer unrelated video edit can therefore carry an older pointer. [Database+BrandSync.swift:469](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+BrandSync.swift:469), [Database+BrandSync.swift:534](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+BrandSync.swift:534).

4. **Make transcript operations explicitly set-scoped.** Changing `activeTranscriptPredicate` alone leaves default transcript reads, speaker-turn writes, backups, and translations selecting the newest set. [Database+Transcripts.swift:118](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Transcripts.swift:118), [Database+Videos.swift:413](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Videos.swift:413).

5. **Replace the proposed fingerprint input definition.** Notes affect the analysis prompt, while several effective inputs are missing from `AnalysisRunSettings`. Excluding notes can suppress requested work; hashing the entire remaining struct includes irrelevant paths and captured prompt previews. [Analyzer.swift:1779](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1779), [AIRunSettings.swift:33](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/AIRunSettings.swift:33).

6. **Resolve the retention contract.** “Auto-deletion is never done” conflicts with pruning transcript sets on write and with the overwrite setting. People Undo also deliberately replaces the better roster rather than keeping it active. These are product decisions, not implementation details. [Analysis-Runs-Plan.md:38](/Users/abghandour/repos/ClipBuilder/docs/Analysis-Runs-Plan.md:38), [Analysis-Runs-Plan.md:129](/Users/abghandour/repos/ClipBuilder/docs/Analysis-Runs-Plan.md:129), [Analysis-Runs-Plan.md:143](/Users/abghandour/repos/ClipBuilder/docs/Analysis-Runs-Plan.md:143).

## Ranker validity

| Proxy | Stored/computable? | Assessment and recommendation |
|---|---|---|
| Scene-pass completion | Partially | Checkpoints contain an optional `runID`, but represent the whole workflow, including later transcription and fight scoring. A complete scene batch can still have an unfinished checkpoint. Discarding the checkpoint erases that evidence. Store completion per layer; do not infer historical scene quality from checkpoint absence. [AnalysisCheckpoint.swift:28](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/AnalysisCheckpoint.swift:28), [AppStore+Analysis.swift:259](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:259), [AppStore+Analysis.swift:474](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:474). |
| Pipeline version | Yes, sometimes absent | Useful provenance and compatibility information, not demonstrated quality. Legacy settings are optional. Define unknown-version treatment and compatibility separately from ranking. [AIRunSettings.swift:51](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/AIRunSettings.swift:51). |
| Type fit | Yes | Q&A/action tags are available. Prefer eligibility or a modest preference; tag presence does not establish correct exchanges or action detection. Podcast tags are generated mechanically from accepted exchanges. [PodcastAnalysisService.swift:435](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/PodcastAnalysisService.swift:435). |
| Scene coverage | Yes | Compute the **union** of eligible intervals, clipped to the comparison domain. Existing union logic can help. **Hypothesis:** more coverage means better analysis; broad or inaccurate ranges can score higher. Podcast chapters overlap their exchanges, so summing durations is invalid. [BatchComparison.swift:96](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/BatchComparison.swift:96), [PodcastAnalysisService.swift:137](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/PodcastAnalysisService.swift:137). |
| Tag density | Yes, weak discriminator | Scenes originate from tag ranges, so having a tag is largely inherent in their creation. Define “system tag” precisely; person-only and structural podcast tags complicate the metric. [Database+Analysis.swift:380](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Analysis.swift:380), [Database+Analysis.swift:403](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Analysis.swift:403). |
| Person attribution share | Yes | Measures attribution presence, not correctness. Conditioning it on the current roster makes old scores change after unrelated roster updates. Snapshot the relevant roster evidence or identify this as a context-dependent score. |
| Sampling density | Requested settings only | `0` means automatic, not densest. Frame caps increase actual intervals. Smart Sampling may be requested but not applicable; the store subsequently saves the requested flag over the analyzer’s effective flag. Store actual sampling metrics before claiming “denser sampling.” [Models.swift:474](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Models.swift:474), [Analyzer.swift:214](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:214), [Analyzer.swift:1959](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1959), [AppStore+Analysis.swift:273](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:273). |
| Full versus trimmed | Yes | This is a scope preference. Comparing coverage against different denominators is misleading: 100% of a short trim does not equal 100% of the recording. Rank full-video candidates separately or make scope an explicit tier. |
| Transcript speech coverage | **No, as proposed** | Introduce independent speech-activity intervals, or initially show transcript span without calling it speech coverage. Existing transcript features derive speech/silence from transcript segments themselves, so using them as independent ground truth would be circular. [TranscriptFeatureAnalyzer.swift:14](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TranscriptFeatureAnalyzer.swift:14). |
| Repetition/hallucination | Computable | The 4-gram rule and 15% threshold are unvalidated hypotheses. Repeated questions, names, quotations, and legitimate conversational repetition need evaluation before automatic penalties. |
| Language match | Partially | Stored language is available; an independent, persistent detected-language reference is unspecified. Do not favor a set merely because it agrees with its own detected language. |
| Mean confidence | Cheap to add | The recognizer computes a mean, but substitutes `0.5` when confidence is unavailable. Preserve missingness rather than recording that fallback as measured confidence. Cross-model comparability is unvalidated. [TranscriptionService.swift:332](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TranscriptionService.swift:332). |
| Segment-length sanity | Yes | Re-cutting changes segment boundaries without improving recognition. Score original recognizer output, or treat this as formatting diagnostics. [Database+Transcripts.swift:143](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Transcripts.swift:143). |
| Roster names/portraits/count | Mostly | Names and portrait boxes exist, but “two fighters plus others” is not a numeric expected count. Tile count is available for podcasts, yet identities can change over time. Suitable for an Undo explanation, not established quality ranking. [Models.swift:413](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Models.swift:413). |

Further requirements:

- Define exact normalization, weights versus lexicographic tiers, empty-input handling, and a portable final tie-breaker. “In order of weight” does not specify a deterministic algorithm.
- Exclusions, trims, and person tags are editable. Automatic re-ranking after an editor hides poor scenes could move away from their curated batch. Prefer immutable analysis metrics, or explicitly preserve curated choices.
- Confidence must survive cache restoration, re-cutting, backup restoration, and sync—not just initial insertion.

## Active-batch filtering impact (with file:line evidence)

Use explicit scopes such as **active discovery**, **specified batches/all history**, and **referenced scene IDs**. `fetchScene(id:)` should resolve an existing historical scene regardless of the active pointer.

| Consumer | Impact and required change |
|---|---|
| Library snapshot and direct lookup | Both currently delegate to `fetchScenes`. A blanket predicate would also hide individual historical scene IDs. Preserve unfiltered identity lookup. [Database+Analysis.swift:8](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Analysis.swift:8), [Database+Analysis.swift:14](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Analysis.swift:14). |
| Saved Wizard/selection takes | `resolvedPlan` matches video/path/range and chooses the highest matching scene ID; it does **not** prefer the original scene ID or batch. With active-only inputs, different boundaries invalidate the take; identical boundaries can silently remap its source scene. Historical resolution must prefer the stored identity first. [WizardSelectionRules.swift:39](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Wizard/WizardSelectionRules.swift:39). |
| Legacy take hydration | The lazy upgrade reconstructs references through `fetchScenes`. Hydrate from history before filtering, or old takes can remain without usable footage references. [Database+WizardSelections.swift:257](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+WizardSelections.swift:257). |
| New Wizard planning | Active-only defaults are appropriate, but explicit `selectedRunIDs`, copied source IDs, and handed-off selections need historical access. Otherwise choosing an older batch produces an empty pool. Also replace `latestRunIDs` with active resolution. [WizardEngine.swift:1860](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/WizardEngine.swift:1860), [WizardView.swift:303](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/WizardView.swift:303). |
| Builder timelines | The library snapshot replaces Builder’s scene cache. Modern clips retain file/time fallbacks, so many continue rendering, but scene-based framing can change; older scene-only clips can disappear because unresolved clips are skipped. Hydrate every document’s referenced scenes independently. [AppStore.swift:1280](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore.swift:1280), [BuilderStore.swift:1296](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/BuilderStore.swift:1296), [MultitrackRenderer.swift:968](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/MultitrackRenderer.swift:968), [MultitrackRenderer.swift:1005](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/MultitrackRenderer.swift:1005). |
| Generated videos | Existing rendered files are not deleted by changing discovery. However, legacy output source grouping resolves scene IDs through the supplied scene map, and critic evaluation reloads that map through `fetchScenes`. Preserve historical metadata for regrouping, evaluation, and re-rendering. [OutputFolders.swift:101](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/OutputFolders.swift:101), [CriticEvaluator.swift:34](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/CriticBrief/CriticEvaluator.swift:34). |
| ScenesView and Compare | Both consume `store.scenes`. They need their own explicit historical scope for old-batch browsing, comparison, editing, and grading. Compare’s **Merge** only excludes duplicates in other batches; their unique scenes remain there and would disappear from active-only discovery. Define a real merged collection/batch or change that action’s semantics. [ScenesView.swift:129](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/ScenesView.swift:129), [CompareBatchesSheet.swift:22](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/CompareBatchesSheet.swift:22), [CompareBatchesSheet.swift:267](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/CompareBatchesSheet.swift:267). |
| Search and scene index | The examined index is in memory, rebuilt when `scenes` changes; natural-language search builds rows from its supplied candidates. Update candidate scope and invalidate outstanding results when activation changes. “All batches” search must remain possible. [AppStore.swift:202](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore.swift:202), [AppStore+AITools.swift:168](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+AITools.swift:168). |
| Moments | Persisted `moments` have video/time, **no run association**. Filtering scenes cannot identify which moments belong to the active batch. The plan needs a migration/provenance policy; its “moments-to-scene lookups” wording does not address these rows. [Database+Analysis.swift:418](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Analysis.swift:418), [Database+People.swift:452](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+People.swift:452). |
| Coverage and fight scoring | Coverage still chooses the latest run internally, so supplying active scenes alone mixes two batches’ evidence. Fight scoring replaces the video’s events and clears them when its scene pool has no action tags. Resolve the scene batch at the correct pipeline stage and record which batch produced the score. [AnalysisCoverage.swift:55](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/AnalysisCoverage.swift:55), [Analyzer.swift:1278](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1278). |
| Training/history consumers | Training retrieves labeled scenes through `fetchScenes`; active-only filtering would omit historical labeled examples. These are identity/history consumers. [AppStore+ReelModels.swift:23](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+ReelModels.swift:23). |

Deletion needs separate protection. `deleteAnalysisRun` removes scenes immediately, while selection references live in JSON rather than scene foreign keys. Pointer repair alone does not protect saved work. Add reference-aware confirmation or archival behavior, and perform Keep/Delete/pointer replacement atomically. [Database+Analysis.swift:355](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Analysis.swift:355), [Database.swift:240](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database.swift:240).

## Transcript sets

**The basic storage mechanism already exists, but activation must reach every reader and writer.**

- **Separate newest from active.** Keep a genuine chronological `latestTranscription`; add one shared active resolver used by transcript reads, captions, language availability, counts, speaker turns, re-cutting, and backups.
- **Allocate new keys only for new original transcriptions.** Translation and re-cutting must retain their source set. Return the created key to the caller and pass it explicitly through subsequent work.
- **Capture translation identity before awaiting.** Translation currently receives original rows, performs asynchronous work, then writes through `replaceTranscripts`, which selects the newest key at write time. A new set arriving meanwhile can receive translations from the old set. Both the existing-translation lookup and final write need the captured key. [TranscriptTranslator.swift:118](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TranscriptTranslator.swift:118).
- **Scope speaker-turn writes explicitly.** `replaceSpeakerTurns` currently derives its key from newest transcription. If ranking retains the older active transcript, merely changing that lookup to “active” can still attach turns computed from the new transcript to the wrong set. Pass the source key through the whole job. [Database+Videos.swift:413](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Videos.swift:413).
- **Migrate backups structurally.** `transcript_backups` has a video-only primary key. It needs `(video_id, transcription_key)` or equivalent set ownership, plus compatible migration of old JSON. New transcription currently deletes every backup for the video. [Database.swift:145](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database.swift:145), [Database+Transcripts.swift:95](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Transcripts.swift:95).
- **Address derived data.** Transcript features, cleanup proposals, topics, voice profiles, and podcast layout remain video-scoped. Switching the transcript alone can expose derived data from another set. Version them or invalidate/recompute them deliberately. Podcast scene batches should record the transcript set used to produce their exchanges. [Database+Transcripts.swift:301](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Transcripts.swift:301), [Database+Videos.swift:438](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Videos.swift:438), [PodcastAnalysisService.swift:98](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/PodcastAnalysisService.swift:98).

The existing picker already loads historical transcripts and matching turns. Extend it with active/pinned state rather than creating another picker. Its current editable mode is tied to the empty “Newest” selection, which must change. Also, `transcriptionSets()` aggregates translations with originals and uses `MAX(model)`, so its displayed model can describe a translator. [TranscriptSheet.swift:231](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/TranscriptSheet.swift:231), [TranscriptSheet.swift:244](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Views/TranscriptSheet.swift:244), [Database+Transcripts.swift:33](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+Transcripts.swift:33).

**Migration:** FootageSync assigns one shared legacy key to null-key transcripts and speaker turns, with a 1970 timestamp. Preserve those keys; backfill backups to them. Do not rekey existing synchronized rows when adding active pointers. [Database+FootageSync.swift:46](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+FootageSync.swift:46).

## Sync

1. **Natural keys are appropriate, with qualifications.** Videos use content hash; runs use `(video_id, created_at, run_key)`. Scope pointer validation to the owning video. Run keys already exist for pre-sync runs after migration: old rows are backfilled, and insert triggers generate keys even without an attached sync binding. The missing piece is exposing `run_key` through `AnalysisRun` and fetch hydration—not generating every historical key anew. [SyncTable.swift:109](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TeamSync/SyncTable.swift:109), [Database+FootageSync.swift:30](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+FootageSync.swift:30), [Database+BrandSync.swift:41](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+BrandSync.swift:41), [Models.swift:465](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Models.swift:465).

2. **Whole-row ordering is insufficient for per-layer choices.** A video timestamp orders the last video update, not the last scene-selection or transcript-selection decision. Define atomic per-layer selection records with decision revisions, pin/unpin operations, and deterministic conflict resolution. Alternatively, explicitly accept whole-row last-write behavior and remove the stronger promise.

3. **Distinguish missing, pending, and deleted targets.** Videos precede runs/scenes/transcripts in sync order. A pointer may arrive before its target or before all candidate rows/tags. Do not overwrite it or rank incomplete data on each partial arrival. Plain text pointers also bypass existing declared-reference parent recovery. [SyncTable.swift:109](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TeamSync/SyncTable.swift:109), [SyncEngine.swift:70](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TeamSync/SyncEngine.swift:70), [Database+BrandSync.swift:424](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Data/Database+BrandSync.swift:424).

4. **Prevent automatic selection churn.** Hypothesis: devices with different ranker versions, language preferences, toggles, or local checkpoints choose different winners and repeatedly sync them. Prefer locally derived automatic picks and synchronized manual choices, or synchronize all ranking inputs and the ranking policy/version.

5. **Define a portable people snapshot DTO.** Do not serialize local `personID` values as cross-device references. Preserve person keys, portrait geometry, ranges, detection metadata, and comparison metrics. Generic JSON portability handling strips paths but does not remap nested IDs. Also, names/descriptors are changed before `replaceVideoPeople`, so a snapshot taken there cannot undo the complete people pass. [Analyzer.swift:1099](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/Analyzer.swift:1099), [SyncMapping.swift:184](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TeamSync/SyncMapping.swift:184).

6. **Add server migration and mixed-client policy to each phase.** Pointer fields and confidence require remote columns and descriptors. The engine currently gates schema version exactly; include rollout sequencing and tests rather than treating sync as an automatic consequence of local columns. [SyncEngine.swift:55](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/TeamSync/SyncEngine.swift:55).

## Duplicate-run prevention

Use an explicit, versioned request representation instead of “`AnalysisRunSettings` minus notes.”

**Include inputs that change output:**

- Source identity captured when the request starts.
- Effective video type, pipeline/pass versions, trim and sampling policy.
- Instructions **and timestamped notes**.
- Required people, relevant identity markers, and relevant profile tags/taste inputs.
- Effective model routing and on-device policy.
- Transcript dependency and podcast settings where applicable.
- Requested pass set, including fight scoring.

The current call path uses notes, known people, markers, on-device switches, podcast thresholds, and speaker-hold settings outside the proposed snapshot. [AppStore+Analysis.swift:70](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:70), [AppStore+Analysis.swift:168](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:168), [AppStore+Analysis.swift:217](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:217).

**Exclude incidental representation:** local paths, display names, run names, and captured prompt previews. Canonicalize unordered collections and automatic defaults. Persist the normalized request alongside its hash so the UI can explain differences.

Additional requirements:

- Compare against a **successful matching request**, not only the active winner. Otherwise, a completed run that loses ranking can be repeated indefinitely.
- Resume unfinished checkpoints before applying duplicate-skip logic; current Analyze deliberately resumes the checkpoint’s saved settings. Capture the request before consuming one-shot defaults. [AppStore+Analysis.swift:49](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:49), [AppStore+Analysis.swift:123](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:123).
- “Missing passes only” needs explicit per-pass readiness. `AnalysisCoverage.Report` currently has no people or fight-pass inputs. Completed-empty and failed are different outcomes. [AnalysisCoverage.swift:24](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/AnalysisCoverage.swift:24).
- `reanalyzeBatch` restores only instructions, interval, transcript flag, and provider/model. Restore the full effective request before promising a same-settings comparison. [AppStore+Analysis.swift:482](/Users/abghandour/repos/ClipBuilder/ClipBuilder/App/AppStore+Analysis.swift:482).

**Source detection needs correction.** `SourceIdentityCache` currently uses `URL.resourceValues`, contrary to the plan’s stated requirement. Its underlying content hash samples the first/last megabyte plus size; a same-size middle-only edit is undetectable by that hash, even after cache invalidation. Replace the metadata calls and document sampled-identity limits or use stronger verification for stale-source decisions. Because hash is also the video’s sync natural key, do not casually mutate it to acknowledge an in-place source replacement. [SourceIdentityCache.swift:38](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/SourceIdentityCache.swift:38), [FFmpeg.swift:347](/Users/abghandour/repos/ClipBuilder/ClipBuilder/Services/FFmpeg.swift:347).

## Phase order

Recommended sequence:

1. **Foundation:** explicit scene scopes, historical identity resolution, portable keys, completion/dependency metadata, deletion semantics, and sync conflict design.
2. **Revised A:** active discovery with newest default and manual pin/unpin. Preserve saved takes, Builder documents, Compare, and historical browsing. Include server migration.
3. **Preservation portion of C:** new transcript keys, set-scoped operations, backup migration, existing picker activation, and derived-data policy. No pruning or automatic quality selection yet.
4. **D:** request fingerprints and resume-aware duplicate prevention. This reduces redundant work without relying on speculative quality scores.
5. **B:** scene recommendations first; enable automatic selection after validating real examples.
6. **Ranking portion of C:** ship only validated transcript signals.
7. **E:** roster Undo with an accurately bounded promise about what it restores.

Verification should include inactive-batch saved-take rendering, legacy take hydration, Builder framing stability, Compare Merge behavior, pointer-before-target sync arrival, concurrent pin/automatic updates, translation finishing after a set switch, and migration of existing transcript backups.

## Answers to open questions

1. **Older pipeline versus coverage:** Allow a compatible older pipeline to win when evidence is materially better. Use hard exclusion only for a known invalid/incompatible pipeline. Version alone is not quality; show “older pipeline” independently of the recommendation.

2. **Three transcript sets:** Keep all by default initially. Three historical sets can be a visible default list, not a deletion policy. If retention is later introduced, protect edited, referenced, active, and explicitly retained sets; the proposed single active pin does not represent multiple retained historical sets.

3. **Record batches in saved takes:** **Yes, per source.** Add run key and stable scene identity to footage references; retain source/range fallback for migration and recovery. Resolve the exact historical scene before any remapping. Add transcript-set provenance if re-rendered captions and speaker framing must also remain reproducible.

4. **Ship the hallucination heuristic unmeasured:** **Only as an informational diagnostic.** Do not let it automatically demote or disqualify sets until evaluated against representative transcripts, including legitimate repetition and different segmentation styles.

## Smaller nits

- The resolver says a missing pinned target falls back, but persistence is allowed only for nil or unpinned pointers. Specify repair after confirmed deletion separately from temporary sync absence. [Analysis-Runs-Plan.md:64](/Users/abghandour/repos/ClipBuilder/docs/Analysis-Runs-Plan.md:64).
- Add a visible **Use automatic choice / Unpin** action. “Make active” alone creates a permanent manual choice without a stated way back.
- Coverage’s pipeline must come from the active scene batch, while unfinished-work status remains separate. Otherwise the UI can show an old active batch as current because a newer inactive batch exists.
- The status column already has fixed slots and a minimum width of 334 points; integrate the batch control into that budget a
