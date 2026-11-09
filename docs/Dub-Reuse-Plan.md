# Dub Reuse Plan

2026-11-09 · Status: implemented 2026-11-09 (Phases 0-5), unreleased. The server migration 20261109120000_dub_takes.sql must be applied at release time, together with the client that understands sync schema 12.

Goal: pay ElevenLabs once for a piece of source speech. A scene that has been
dubbed once, in any timeline, Wizard render or by any teammate, is re-dubbed
for free unless its text or voice really changed.

## What happens today

- Translations are already reused. `DubTranslationGate.ensure` stores the
  translated transcript rows per video and language, so a second dub of a
  scene does not translate again.
- Audio is cached locally by exact string. `ElevenLabsDubSynthesizer` keys
  `.cache/dubs/<sha>.caf` on `voice # model` + the line text. Rate changes are
  done with atempo from the rate-1 file, so fitting costs no credits.
- Credits are still spent again in these cases:
  1. **Line text depends on the clip's trim.** `DubPlanning.lines` cuts each
     translated row to the clip's source span (`trimmedText`). Two clips of
     the same scene with different in/out points produce different strings.
     Each string is a cache miss, so the overlapping speech is paid twice.
     Wizard variants built from the same scenes hit this constantly.
  2. **Review edits stay in one timeline.** A corrected line or speaker lives
     only in that timeline's `dub_lines`. The next dub of the same scene
     starts again from the raw translation and pays for it. Then the user
     edits the line again and pays again.
  3. **Every line is voiced before review.** Preparation synthesizes all
     lines with ElevenLabs. Each line edited in review is paid at least twice.
  4. **The cache is per Mac and disposable.** It lives under
     `data/.cache/dubs` (1,004 files, 249 MB on this Mac). Teammates pay
     again for identical speech, and clearing the cache loses paid audio.
  5. **Cosmetic text differences miss the cache.** Changes in whitespace or
     Unicode form produce a different key.
- The cache key also has a correctness gap. Stability and similarity are not
  in it, so changing them silently serves the old audio.

## Design: dub takes

A **take** is one paid ElevenLabs request for one whole translated transcript
row, together with the timings that let any part of it be reused.

```
dub_takes (profile DB)
  id, video_id, transcription_key, row_start, row_end, language,
  speaker_key, text, voice, model, settings_hash,
  audio_file,            -- leaf name in <profile>/dub-takes/
  alignment_json,        -- character start/end times from ElevenLabs
  edited                 -- 1 when the text came from a review edit
  created_at, updated_at
unique (video_id, transcription_key, row_start, row_end, language, voice, model, settings_hash)
```

- **Synthesize rows, not fragments.** Use
  `POST /v1/text-to-speech/{voice}/with-timestamps`. It costs the same as
  plain text-to-speech and returns character alignment. A clip that covers
  only part of a row cuts the take at the nearest word boundaries with
  ffmpeg `atrim`. Any in/out point inside an already voiced row then costs
  nothing.
- **Look up before paying.** `DubPreparation` resolves each planned line to
  its row. It looks up a take for (row, language, voice, model, settings).
  On a hit the take's audio is cut and fitted locally; only misses call
  ElevenLabs.
- **Edits become source facts.** Update lines and Apply write the reviewed
  text and speaker back to the row's take, with `edited = 1`. The next dub of
  that scene, in any timeline or Wizard run, starts from the reviewed text.
  That text is already voiced. An edit to a partial line is stored as an
  override for that sub-span. A later clip with the exact same span reuses
  it; other spans fall back to the row take.
- **Keep paid audio out of the cache.** Takes live in the profile folder
  (`<profile>/dub-takes/`) and are never evicted with `.cache`. The existing
  `.cache/dubs` files stay the fitted, derived copies.
- **Takes live as long as their video.** Removing a video from the profile
  deletes its `dub_takes` rows and their audio files, locally and, through
  the synced tombstone, for teammates. Nothing else deletes takes.

## Phases

### Phase 0: measure (small)
- Log reused versus requested characters per dub job, in the job's status
  line and the unified log.
- The Dub start dialog shows an estimate before anything is spent: "≈ 1,240
  credits · 18 of 24 lines reuse earlier audio".
- Exit: a week of real jobs tells us which of the waste cases above
  dominates.

### Phase 1: cache hygiene (small)
- Normalize text before hashing: Unicode NFC, collapse whitespace, trim.
- Add stability and similarity to the cache key. This is a correctness fix
  and slightly increases misses after a settings change.
- Tests: identical speech with spacing differences shares one file; a
  settings change does not.

### Phase 2: row takes with timestamps (main saving)
- `ElevenLabsClient.speakWithTimestamps` (base64 audio + alignment).
- `dub_takes` table, migration, and `Database+DubTakes.swift`.
- A pure `DubTakeCutter` (nonisolated, tested) maps a line's source span to
  a word-aligned time range in the take.
- `DubPreparation.fit` asks the take store first. `ElevenLabsDubUsage` counts
  only real requests.
- Mac and Siri voices keep the current path; they cost nothing.
- Video removal deletes the video's takes and files in the same pass that
  removes its other rows.
- Before relying on it, confirm with one request that `with-timestamps`
  costs the same as plain text-to-speech (compare the subscription's
  character count before and after). The API reference does not state it.
- Exit: dubbing a second timeline built from the same scenes, with
  different trims, logs 0 ElevenLabs characters.

### Phase 3: reviewed edits carry over
- Decided: edits carry over automatically, with no prompt. A fix made in
  one timeline is the scene's wording for every later dub.
- `applyDubReview` and `updateDubReview` upsert takes with `edited = 1`, and
  speaker corrections become row speaker overrides.
- Planning prefers an edited take's text over the raw translation, and the
  review sheet marks those lines "Reviewed earlier".
- Exit: correct a line once, dub the scene in a new timeline, and the
  correction is there, already voiced, at no cost.

### Phase 4: pay only for what survives review
- Decided: drafts use ElevenLabs Flash v2.5 (`eleven_flash_v2_5`) with the
  same voice, including clones. Flash costs 0.5 credits per character on
  self-serve plans against 1 for Multilingual v2, and it sounds close to the
  final voice, so timing changes little on Apply.
- Review and edits happen on the draft. Apply re-voices only the final lines
  with the chosen model and re-fits their timing. Draft audio is cached by
  model like any other line, never stored as a take.
- Lines that already have a take skip the draft.
- Wizard render dubs default to reuse plus draft, so variants that are
  thrown away cost nothing.

### Phase 5: share takes with the team
- Sync `dub_takes` rows through Team Sync. This needs the Supabase column
  migration first, or PostgREST rejects the whole table's push.
- Decided: upload take audio to the team Drive folder; teammates download it
  instead of synthesizing. A take whose file is not uploaded yet is
  synthesized locally as today, then uploaded.
- Side effect: teammates on another ElevenLabs account can use audio made
  with a clone they cannot call themselves.

## Decisions (2026-11-09)

1. Takes are kept until their video is removed from the profile, then
   deleted with it.
2. Take audio is shared through the team Drive folder.
3. Drafts use the cheaper Flash model.
4. Reviewed edits carry over to future dubs of the scene automatically.

## Out of scope

- ElevenLabs Dubbing API (whole-video dubbing). It is priced per minute and
  would replace the reviewed, line-level pipeline.
- Re-voicing when a clone is re-cloned. New voice ID means new takes, by
  design.

## Run A implementation (2026-11-09)

- Local schema 47 → 48 adds `dub_takes` and `dub_speaker_overrides`. No server
  migration, sync gate, or SyncTable changes. Take IDs hash the video's content
  hash plus the transcript/span/language/voice/model/settings natural key;
  local integer video IDs are not part of that ID.
- Durable profile audio is stored beside the profile library at
  `<data>/profiles_db/<profile-library-stem>/dub-takes/<take-id>.caf`.
  Rows reference leaf names. Derived cuts and fitted files remain in `.cache/dubs`.
- Both timeline and Wizard preparation use the shared row-take path. Existing
  source word times are honored; otherwise source words are distributed across
  the row as before. Missing/unusable alignment uses whole-row audio for full
  lines and plain synthesis for fragments. Rendering restores cleared derived
  audio from takes. Mac and Siri keep their synthesis paths.
- Reviewed full-row text and exact-span overrides carry forward automatically;
  speaker corrections apply to the original row. Legacy reopened timelines
  resolve row metadata before accepting new corrections. A source retirement
  deletes takes and their files; a team-local hide preserves them.
- Added `DubTakeCutterTests` (5), `DubCacheIdentityTests` (3), and
  `DubTakeStoreTests` (9). Updated existing schema, cache identity, and usage-log
  assertions. Swift parsing and a limited service typecheck passed; Debug
  build-for-testing and the targeted suite run both exited 143 during Xcode
  startup, before compilation/test execution. No full suite or Release build ran.
- Still unverified: actual timestamp API billing equivalence, live two-timeline
  credit reuse, reviewed carryover in the UI/Wizard, and native test results.
  No live paid API calls were made during implementation.


## Run B implementation (2026-11-09)

- Phase 4: shared preparation (Builder and Wizard) and Update lines first try
  final-model takes, then cache Flash v2.5 drafts using the same voice. Drafts
  have an optional `DubLine.draft` marker, never create takes during preparation,
  and show “Draft voice” in review. The credit caption estimates final Apply
  work, excluding reusable final audio and including draft lines.
- Apply closes the sheet and runs a cancellable “Finalize dub” AppJobs job.
  Only drafts are re-voiced and fitted to their original slots; final lines
  remain unchanged. The job checks profile/database/timeline identity before
  committing. Wizard receives final lines before its continuation resumes;
  stopping either the Wizard or finalization cancels the other waiter. Drafts
  saved through Open in Editor must be reviewed and applied before rendering.
- Phase 5: local schema 49 adds nullable `dub_takes.drive_file_id` and registers
  both dub tables for Team Sync, including seeding existing attached profiles.
  Takes use their content ID as the natural key; speaker overrides use the
  portable video reference plus transcript/span/language. Deletions propagate
  as tombstones and remove local paid files after the sync transaction commits.
- `DubTakeDrive` captures each profile's Drive context, queues unchanged CAF
  uploads to `Dub takes` under its team folder, and uses the existing Drive
  transfer queue with Stop. Dubbing does not await uploads. Pending rows retry
  on reuse; no account/folder leaves local dubbing intact. Missing local takes
  download through an injectable downloader before synthesis. Failed downloads
  fall back; cancellation propagates. Estimates count Drive-backed takes as
  reused. Fully reusable remembered clones stay selected even when absent
  from this Mac's ElevenLabs account.
- Server migration `20261109120000_dub_takes.sql` creates both tables with the
  standard envelope, stamps, RLS and grants; schema version/client gate are 12.
  The migration is written only, not applied to any server.
- Added 16 regression tests across DubTakeStoreTests, AppStoreDubbingTests,
  ElevenLabsDubSynthesizerTests and new SyncDubTakeTests. Existing schema
  assertions/fixtures were updated. No native tests ran in this pass.
- Validation: Swift parsing, a limited service typecheck against the prior
  compiled app with compatibility shims, source-derived SQLite migration and
  trigger smoke checks, server/client column parity, and `git diff --check`
  passed. Debug build-for-testing exited 143 during sandboxed Xcode startup;
  a direct full typecheck was also blocked by sandboxed macro plugins. Claude
  must build, run the targeted suites, review, and verify live Drive/ElevenLabs
  behavior before deployment. No paid requests or remote writes were made.

### Run B file inventory

- App: `AppStore+Dubbing.swift`, `DubReviewCoordinator.swift`.
- Data: `Dubbing.swift`, `DubTake.swift`, `Database.swift`,
  `Database+DubTakes.swift`, `Database+BrandSync.swift`.
- Dubbing services: `DubPreparation.swift`, `DubTakeStore.swift`, new
  `DubTakeDrive.swift`, `DubSynthesizer.swift`.
- ElevenLabs services: `ElevenLabsDubSynthesizer.swift`, `ElevenLabsDubUsage.swift`.
- Sharing services: `GoogleDrive/GoogleDriveTransfers.swift`,
  `TeamSync/SyncTable.swift`, `SyncMapping.swift`, `SyncEngine.swift`.
- Views: `DubReviewSheet.swift`, `DubReviewLineRow.swift`.
- Tests: `App/AppStoreDubbingTests.swift`, `Data/DatabaseTests.swift`,
  `Services/Dubbing/DubTakeStoreTests.swift`,
  `Services/ElevenLabs/ElevenLabsDubSynthesizerTests.swift`,
  new `Services/TeamSync/SyncDubTakeTests.swift`, `SyncHistoryTableTests.swift`,
  `SyncMigrationTests.swift`, `SyncTestSupport.swift`.
- Migration/docs: `supabase/migrations/20261109120000_dub_takes.sql`, this plan,
  and ignored `HANDOFF.md`. Other pre-existing uncommitted files were preserved.
