# Analysis Runs Plan

Date: October 12, 2026. Status: revised the same day after the Codex review in
docs/Analysis-Runs-Codex-Review.md. Phase 1 (foundation + active discovery)
and phase 2 (transcript sets) implemented by Codex on October 12, 2026, uncommitted; Debug build passes and the affected suites pass after Claude review fixes. Phase 3 implemented by Codex on October 12, 2026, uncommitted; direct compiler checks pass, with Xcode and runtime verification pending Claude review. Phases 4 to 6 not started.
Implementation: Codex; build, tests and review: Claude (per the September 23 working rule).

## Problem

Running Analyze on a video that already has an analysis is confusing:

1. **Scene batches accumulate and nothing is current.** Every Analyze inserts
   a new `analysis_runs` row and a new scene set under it; old batches stay
   (`Data/Database+Analysis.swift` L370-454). `fetchScenes` has no run filter
   (L83-115), so the library snapshot, the Analyze status column (scene count
   summed across batches), coverage's Q&A count, scene search and the Wizard
   source pool all see every batch at once. There is no `currentRun` anywhere;
   four places pick "newest" independently.
2. **Transcripts and people silently overwrite.** `replaceTranscripts` reuses
   the latest `transcription_key` and deletes those rows before inserting
   (`Data/Database+Transcripts.swift` L81-115); `replaceVideoPeople` deletes
   the roster and reinserts. A worse re-run destroys a better earlier result.
3. **Nothing stops a duplicate run.** `analyze()` has no "already up to date"
   check; coverage compares only the latest run's pipeline integer.

The ask: tell which analysis is better per layer, keep the better one active,
hide the others.

## Principles

- **Per layer, not per run.** Scenes, transcript and people are independent.
- **Three scopes, always explicit.** *Discovery* (what new work sees: the
  active batch), *history* (every batch, for browsing, comparing, training and
  legacy hydration) and *identity* (a referenced scene id resolves if it
  exists, whatever the active pointer). No reader is changed from history to
  discovery without being named in this plan.
- **Manual choices sync; automatic picks are local.** A pin is a decision and
  travels with the team. An automatic pick is derived on each machine from
  synced data and a versioned local policy, so devices never fight over it.
- **Keep everything.** No pruning, no auto-deletion. Deleting a batch is a
  user action with a reference-aware confirmation.
- **Rank with reasons, ship recommendations before automation.** A ranker is
  first shown as a recommendation; automatic activation turns on only after
  it is validated on real runs.
- **A video with one run behaves exactly as today.**

## Design

### 1. Pointers and keys

Optional, lazily migrated columns on `videos`; portable keys only:

| Column | Meaning | Synced |
| --- | --- | --- |
| `active_run_key TEXT` | pinned scene batch (`analysis_runs.run_key`) | yes |
| `active_transcription_key TEXT` | pinned transcript set | yes |

Pins are the only persisted choice. "Active" is resolved at read time by a
pure `nonisolated enum ActiveLayers`:

```
active batch = pinned run if it exists locally
             else recommended run (phase 5+, when the setting is on)
             else newest completed run (created_at, then run_key)
```

A pinned key whose target is absent locally is kept, not repaired; the
resolver falls back for that read and the UI shows "pinned batch not on this
Mac yet". Repair happens only when the user deletes the pinned batch (the
delete clears the pin in the same transaction) or unpins. "Use automatic
choice" is a visible action next to every pin.

`AnalysisRun` exposes `runKey` (already stored and backfilled by the Footage
Sync migration; triggers generate it for new rows). Nothing is rekeyed.

### 2. Scene scopes

`Database` gets three entry points and every caller is assigned to one:

- `fetchScenes(projectID:scope: .active)` for **discovery**: the library
  snapshot's `store.scenes`, the scene search index candidates, the Wizard
  source pool when no explicit batch is selected, coverage `qaCount`, the
  fight scorer's action scenes, the Analyze status scene count.
- `fetchScenes(projectID:scope: .history)` or `(videoID:runKey:)` for
  **history**: ScenesView batch sidebar and "All batches", Compare, training
  (`AppStore+ReelModels`), legacy take hydration
  (`Database+WizardSelections` L257), output regrouping, critic evaluation.
- `fetchScenes(ids:)` for **identity**: saved Wizard and selection takes
  (`WizardEngine` L2593, L2702; `WizardSelectionRules.resolvedPlan` tries the
  stored scene id first, then falls back to video + range), Builder documents
  (each document hydrates its referenced scene ids independently of
  `store.scenes`; `BuilderStore` L1296), moments-to-scene lookups.

`store.scenes` becomes discovery scope. A second store collection,
`store.referencedScenes`, holds identity-resolved scenes for open Builder
documents and saved takes so framing and rendering are unchanged when the
active batch moves. `WizardView.latestRunIDs` is replaced by the resolver;
an explicit `selectedRunIDs` still reads history.

Moments have no run association and stay per video; they are shown for every
batch. Compare's Merge is changed to produce a real merged batch (new run with
the union of unique scenes) so nothing disappears from discovery.

Deleting a batch: the confirmation lists references (saved takes, Builder
documents, generated videos) that point at its scenes, and the delete, the
pin clear and the pointer fallback run in one transaction.

### 3. Pass completion and provenance

`analysis_passes` (from the strike stats work) gains the pass kinds
`scenes`, `transcript`, `people` next to `fightScore` and `strikePose`, each
row carrying `run_key` or `transcription_key` where it applies. Completion is
per layer; a run is "completed" when its `scenes` pass row is completed. An
unfinished checkpoint no longer implies an incomplete scene batch. The fight
scorer records which batch it read. Podcast batches record the transcript set
that produced their exchanges in `settings_json`.

Coverage reads the active batch's pipeline and the pass table, and reports
unfinished work separately, so a newer inactive batch never makes an active
batch look current or stale by accident.

### 4. Transcript sets

- A new original transcription allocates a new `transcription_key` and
  returns it; the previous set stays. Translation and re-cutting keep their
  source set: callers capture the key before awaiting and pass it to the
  write (`TranscriptTranslator` L118, `replaceSpeakerTurns`
  `Database+Videos` L413, re-cut in `Database+Transcripts` L143).
- `latestTranscription` stays chronological. A separate
  `activeTranscription(videoID:)` resolves pin, else newest, and every reader
  (captions, language availability, counts, speaker turns, backups,
  Transcript sheet default) goes through it. `activeTranscriptPredicate` is
  rewritten against the resolved key.
- `transcript_backups` is migrated to a `(video_id, transcription_key)` key;
  old rows are backfilled to the legacy key from the Footage Sync migration.
- Derived per-video data (transcript features, cleanup proposals, topics,
  voice profiles, podcast layout) records the set it came from and is
  recomputed on demand when the active set differs.
- The existing Transcript sheet picker gains active and pinned state, Make
  active and Use automatic; its editable mode follows the active set, not the
  "Newest" slot. `transcriptionSets()` separates translations from originals.
- Nothing is pruned.

### 5. Rankers (recommendations first)

All `nonisolated`, deterministic, versioned (`policyVersion`), computed off
the main actor from stored data only, returning ordered candidates with
reason strings. A Settings toggle "Choose the best batch automatically"
(off until validated) lets the resolver use the recommendation.

**`SceneBatchRanker`**, lexicographic tiers then score:

1. Eligibility: `scenes` pass completed; pipeline known and compatible with
   the video type (unknown or incompatible is listed but never recommended).
2. Scope tier: full-video runs rank above trimmed runs; trimmed runs compete
   only with each other.
3. Score, equal weights, each 0 to 1: union coverage of non-excluded scene
   intervals over the comparison domain (reusing `BatchComparison` union
   logic; podcast chapters and exchanges are unioned, never summed); share of
   scenes carrying a non-structural tag (structural = `q&a`, `chapter`,
   `person:*`, `portrait-fit:*`, `round:*`); person attribution share
   measured against the roster snapshot recorded in the run's
   `settings_json`, not the live roster; actual sampling density recorded by
   the analyzer at run time (`effectiveInterval`, `effectiveSmartSampling`,
   frame count) rather than the requested settings.
4. Tie: newer pipeline, then `created_at`, then `run_key`.

Curation edits (exclusions, trims, person tags) are not inputs; the score
uses the run's immutable metrics captured at analysis time.

**`TranscriptRanker`** (diagnostic only until validated): transcript span
over video duration (labelled "span", never "speech coverage": no
independent speech-activity signal is stored), mean recognizer confidence
when present (`transcripts.mean_confidence REAL`, written as NULL when the
recognizer reports none, never 0.5), repetition rate shown as a diagnostic
with no penalty, language shown. Recommendation uses span and confidence
only.

**`PeopleRosterRanker`**: a comparison line for Undo only ("previous roster
2 named, this one 0 named"). Never ranks automatically.

### 6. Duplicate-run prevention

`AnalysisRequest` is an explicit, versioned, canonical struct captured when
Analyze starts, before one-shot defaults are consumed and before checkpoint
resume: source identity (`videos.hash`), effective video type, pipeline and
pass versions, trim, sampling policy, instructions, timestamped notes,
required people and identity markers, profile tags and taste inputs, effective
model routing and on-device policy, transcript dependency, podcast settings,
requested pass set. Local paths, display names, run names and prompt previews
are excluded. The normalized request is stored on the run next to its hash.

Analyze compares against any *successful* run with an equal hash, not only
the active one. Equal: the button reads "Analyze again" and a sheet offers Run
anyway / Run missing passes only / Cancel; missing passes come from the pass
table. Different: the tooltip names the differing components. Unfinished
checkpoints are offered for resume before this check. `reanalyzeBatch`
restores the full stored request. Batch Analyze reports "12 analyzed, 5
skipped as up to date".

Source change: `SourceIdentityCache` is switched to
`FileManager.attributesOfItem`; its sampled hash is documented as sampled and
is not changed, since it is the video's sync natural key.

### 7. People undo

`replaceVideoPeople` stores a portable snapshot (person keys, names,
descriptors, portrait geometry, ranges, detection metadata) in
`videos.people_snapshot_json`, captured before the people pass renames or
re-describes anyone, so Undo restores the whole previous roster. One level,
local only, bounded promise in the UI: "Restore the roster from before the
last people run".

### 8. Sync

- Pin columns join the `videos` sync columns; whole-row last-write ordering
  applies, which is acceptable because only manual pins are stored.
- A pin arriving before its target is kept and shown as "not on this Mac
  yet"; nothing re-ranks on partial arrival because automatic picks are
  local and derived at read time.
- Server migration per phase; the sync schema gate means both clients update
  together.

### 9. Controls

- Analyze status column: a batch glyph in the existing fixed slot with "+2";
  popover lists batches with date, pipeline, scene and tag counts, completion,
  the recommendation reason, Pin, Use automatic, Compare, Delete.
- Preview pane: "Active batch: v3 (newest)" with Change…; Transcript row:
  "Set 2 of 3 (pinned)" with Change…; People row: Restore previous roster.
- ScenesView: active mark and reason in the batch sidebar; default selection
  is the active batch; "All batches (3)" remains available.
- Settings, Analysis: "Choose the best batch automatically" (off).

## Phases

1. **Foundation + active discovery.** `runKey` on `AnalysisRun`, pin columns,
   `ActiveLayers`, the three scene scopes with every caller assigned (section
   2), `store.referencedScenes`, saved-take and Builder identity hydration,
   `latestRunIDs` replaced, coverage reading the active batch, `scenes` pass
   rows written by `saveAnalysis`, batch popover with Pin / Use automatic /
   Compare / Delete, reference-aware delete in one transaction, Merge as a
   real batch, server migration for the two pin columns. Newest is the
   default; no ranker. Tests: resolver (pin present, pin missing, nil),
   discovery excludes other batches, identity resolves an inactive batch's
   scene, a saved take from an inactive batch renders its stored scene,
   legacy take hydration uses history, Builder document framing unchanged
   after a pin change, Compare Merge produces a batch with the union, delete
   clears the pin atomically, sync round-trip of a pin.
2. **Transcript sets (preservation).** New key per original transcription,
   set-scoped translation, speaker turns, re-cut and backups, backup
   migration, `activeTranscription` resolver and pin, picker state. Tests:
   re-transcribe keeps the old set, translation written to its captured key
   after a set switch, backups migrate, predicate honours the pin.
3. **Duplicate-run prevention.** `AnalysisRequest`, stored hash, sheet,
   resume-before-check, `reanalyzeBatch` full restore, batch summary,
   `SourceIdentityCache` attributes. Tests: equal request, each differing
   component named, request captured before one-shot defaults, successful
   non-active match counts.
4. **Scene recommendation.** Actual sampling metrics and roster snapshot
   recorded at analysis time, `SceneBatchRanker`, reasons in the popover and
   sidebar, Settings toggle off. Validation: run on the user's existing
   multi-batch videos and record agreement in this doc before the toggle
   defaults on.
5. **Transcript diagnostics.** `mean_confidence`, `TranscriptRanker` as
   diagnostics in the picker.
6. **People undo.** Snapshot column, restore control.

## Verification

Per-phase tests as listed. Hand checks on scratch data after phase 1: a
video with three batches, confirm the status column, popover, Wizard sources,
search and ScenesView default show only the active batch; a saved take and a
Builder timeline built from batch 1 still render after pinning batch 3;
Compare Merge; delete the pinned batch.

## Re-analysis

No re-run is needed. Existing videos resolve to their newest completed batch
and newest transcript set with no pin. Nothing is deleted.
