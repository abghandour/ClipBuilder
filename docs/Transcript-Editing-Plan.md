# Transcript editing: edit, compare, revert, and keep every consumer on the edited text

Date: October 20, 2026. Status: phases 1–4 implemented; full Debug build and live verification pending (environment blocked).

## Goal

The Transcript sheet already lets the user change a line's text (a plain text
field per line, `original_text` kept beside the edit, a per-line Revert). What
it does not do:

1. Make editing visible. The fields look like plain text; nothing says a line
   can be edited, and in Group by Speaker the affordance is invisible.
2. Compare an edit with what the transcriber heard, quickly, in place.
3. Keep every consumer on the edited text. Today only `transcripts.text`
   changes. The per-word timings in `transcripts.words` keep the transcriber's
   words, and several readers build text **from the words**, so after an edit
   they still show and send the original:
   - `TranscriptQATrim.words(for:)` prefers timed words over `text`. The Q&A
     word panel, Express Transcript picks, Highlights trim, and
     `MiniWizardTranscriptRules.text(for:rows:)` (the passage text sent to the
     AI and used for pick labels) all go through it.
   - `CaptionPaging` drops the word clocks when they no longer match the text,
     so captions show the edited text but lose per-word timing.
   - `transcript_features` and `topic_ranges` are derived once at transcription
     time from the original text (`TranscriptionService.enrich`) and feed the
     local podcast exchange pass and Builder scripts.
   - Translations of an edited line are translations of the old text.
   - `AppStore.blurbTranscripts` caches rows per video and is not cleared when
     the sheet saves, so AI work that reads `store.transcriptRows` keeps the
     pre-edit rows until something else drops the cache.
4. Put the whole transcript back to the original in one step.
5. Warn before an action throws edits away.

## Rules

- The edited text is the transcript. Every reader of `transcripts` gets the
  edited text and word timings that describe it. Nothing reads
  `original_text` or `original_words` except the sheet's compare view and the
  revert paths.
- Reverting restores text **and** words exactly as the transcriber produced
  them, and refreshes the same derived data a save refreshes.
- No modal sheet runs long work. Derived refresh after a save (features,
  topics, translations) runs through `AppJobs` when it needs the network
  (translation) and inline on the database actor when it is pure CPU under
  a second (features, topics). See docs/Async-AI-Actions-Plan.md.
- Codable settings and records: new stored properties are Optional.
- All new logic that needs neither the database nor the network lives in a
  `nonisolated enum` under Services with a test next to it.

## Phase 1: data — word timings follow the edit

**Schema.** Add `original_words TEXT` (JSON, nullable) to `transcripts`, bump
`Database.schemaVersion` to 35, and add a migration step
`migrateTranscriptEditedWords` in `Data/Database.swift` that:

- `ALTER TABLE transcripts ADD COLUMN original_words TEXT` when missing.
- Backfills rows edited before this change: for every row with
  `original_text IS NOT NULL AND original_words IS NULL`, set
  `original_words = words` and `words = realign(text, original words)`.

**Realignment.** New `Services/TranscriptWordAlignment.swift`:

```swift
nonisolated enum TranscriptWordAlignment {
    /// Word timings for an edited line, derived from the transcriber's words.
    /// Kept words keep their clocks; inserted or replaced words share the gap
    /// between the nearest kept neighbours (or the row's edges). Nil when the
    /// transcriber gave no words (readers already spread tokens evenly then).
    static func realign(text: String, original: [TranscriptWord]?,
                        start: Double, end: Double) -> [TranscriptWord]?
}
```

Match tokens with a longest-common-subsequence over normalized tokens
(lowercased, surrounding punctuation stripped). A matched token keeps the
original word's `start`/`end` but takes the edited spelling. An unmatched run
is spread evenly between the previous kept word's `end` and the next kept
word's `start` (row `start`/`end` at the edges). The result is sorted,
non-overlapping, and clamped to the row range. Any whitespace-split token of
the edited text becomes exactly one `TranscriptWord`, so `CaptionPaging`'s
"words describe this exact text" check passes again.

**Writes.** In `Data/Database+Transcripts.swift`:

- `updateTranscriptText(id:text:)` and `updateTranscriptTexts(_:)` read the
  row's current `words`/`original_words`, then write
  `original_text = COALESCE(original_text, text)`,
  `original_words = COALESCE(original_words, words)`,
  `text = ?`, `words = realigned`. One transaction for the batch.
- `revertTranscriptText(id:)` sets `text = original_text`,
  `words = COALESCE(original_words, words)`, and nulls both originals.
- New `revertTranscriptTexts(videoID:transcriptionKey:) -> Int` does the same
  for every edited row of a set in one transaction and returns the count.
- New `editedTranscriptCount(videoID:transcriptionKey:) -> Int` for the
  guards and the header count.
- `recutTranscript` and `restoreTranscriptBackup` carry `original_words` in
  their INSERTs the same way they carry `original_text`.
- `fetchTranscripts` maps `original_words` to a new
  `TranscriptRow.originalWordsJSON: String?` (Optional, synthesized Codable;
  the JSON backups in `transcript_backups` decode with it absent).

**Sync and script state.** Add `original_words` to the `transcripts` entry in
`Services/TeamSync/SyncTable.swift` and to the transcripts column list in
`Data/Database+ScriptState.swift` (around line 381) so both carry the edit and
its original together.

**Tests.** `ClipBuilderTests/Services/TranscriptWordAlignmentTests.swift`:
kept words keep their clocks; an inserted word takes the gap; a deleted word
leaves neighbours untouched; a replaced word keeps the replaced word's clock;
punctuation and case do not break a match; nil original gives nil; every
token of the edited text gets exactly one word and the result is monotonic.
A database test next to `TranscriptSetsTests`: edit then revert restores
`text` and `words` byte for byte and nulls both originals; revert-all returns
the count; the migration backfills a pre-existing edited row.

## Phase 2: derived data follows the edit

Add `AppStore.transcriptTextsChanged(videoID:rowIDs:)` in
`App/AppStore+AITools.swift` (next to `transcribe`), called by the sheet after
a save with text changes and after any revert:

1. `blurbTranscripts[videoID] = nil`.
2. Features and topics: make `TranscriptionService.enrich` reachable as
   `refreshDerived(video:database:)` and run it for the active set. It is
   pure CPU over the rows and already keeps decided edit proposals
   (`replaceTranscriptFeatures`). Run it off the main actor.
3. Translations: for each translated language of the set
   (`TranscriptionSet.hasTranslations`), re-translate only the edited rows and
   merge them into the existing translation rows, written with
   `replaceTranscripts(... isTranslation: true)` as the translator does today
   (`Services/TranscriptTranslator.swift`, `translateBatched` already answers
   per row id). Queue it through the same background path auto-translation
   uses (`enqueueAutoTranslation`), so the sheet never waits on it.

Verify, and note in the plan's results section, that nothing else rebuilds
text from the transcriber's words after Phase 1: grep for `.words` readers
(`TranscriptQATrim`, `PodcastHighlightTrim`, `WizardEngine`,
`WizardPodcastBRoll`, `TranscriptSpeakerRecut`, `PodcastAnalysisService`,
`CaptionRenderer`, `MiniWizardTranscriptRules`, `BuilderQuery`,
`AnalysisRequest`). They all read `words`, which now describes the edited
text, so no change is expected; the check is the deliverable.

## Phase 3: the sheet

All in `Views/TranscriptSheet.swift`, visible controls only (no
context-menu-only entry points), every toolbar label `lineLimit(1)` +
`fixedSize`.

**Edit mode.** A bordered `Edit` toggle button in the filters row, after
Group by Speaker. Off (the default, what the screenshot shows): lines render
as selectable `Text`, play buttons and speaker menus as today. On: lines are
the existing text fields with a visible field background, a pencil glyph on
hover, and the Apply/Discard bar. Pending drafts survive toggling the mode off
(the bar stays while `hasChanges`). The header caption becomes
"552 segments · 3 edited" when any row has `originalText`.

**Compare.** A `Compare` toggle beside Edit, enabled only when some row is
edited or has a draft. On: every such row shows, under its text, the
transcriber's line in secondary colour with a word-level diff: words removed
from the original struck through in red tint, words added in the edit shown
in accent tint on the edited line above. The diff comes from a new
`Services/TranscriptTextDiff.swift`:

```swift
nonisolated enum TranscriptTextDiff {
    enum Kind { case same, inserted, deleted }
    struct Token: Equatable { var kind: Kind; var text: String }
    static func diff(original: String, edited: String) -> [Token]
}
```

(LCS over whitespace tokens, exact match.) Test next to it.

**Edited filter.** The tags menu gains "Edited (n)" so the user can list only
the edited lines (same mechanism as "Changed by the map").

**Revert.** The per-line Revert stays. The More menu gains
"Revert All Edits… (n)" with a confirmation
("Put the transcriber's text back on n lines? Their word timings and any
translations and topics derived from the edits are refreshed too.").
It calls `revertTranscriptTexts`, then `transcriptTextsChanged`, then
`load()`. Both revert paths call `transcriptTextsChanged`.

**Save.** `save(thenDismiss:)` calls `store.transcriptTextsChanged` after
`updateTranscriptTexts` when `changes` is non-empty.

## Phase 4: warn before edits are lost

Inventory of every path that replaces or restores transcript rows, with the
decision for each:

| Path | Loses edits? | Guard |
| --- | --- | --- |
| Re-transcribe (sheet More menu; `rerun(.transcript)` from Analyze) | A new set becomes active; edits stay on the old set but stop being used | Confirmation names the count |
| Undo Re-cut (`restoreTranscriptBackup`) | Yes, for edits made after the re-cut | Confirmation when `hasEdits` says so |
| Re-cut by Speaker, Map Speakers Again, Undo Map | No: edited rows pass through whole and `transcriptRecutBase` keeps corrected rows | None; the plan records why |
| Switching the active set / Use automatic / Pin | No: edits live on the set's rows | Picker rows show "· n edited" |
| Discard Changes, closing with drafts | Unsaved drafts only | Existing dialogs stay |
| Full analysis runs (`transcribeForVideo(force: false)`, `cachedPodcast`) | No: stored rows are reused | Verify and note |
| Team Sync pulling transcript rows | Out of scope here; both columns sync | Note only |

Implementation:

- `AppStore.transcriptEditCount(videoID:) async -> Int` wraps
  `editedTranscriptCount` for the active set.
- The sheet's re-transcribe dialog message becomes, when the count is above
  zero: "This transcript has n edited lines. Re-transcribing makes a new
  transcript set; the edited set stays in the sets list but stops being
  active." The destructive button keeps its label.
- `rerun(.transcript, ...)` from the Analyze view: route through a shared
  `ConfirmTranscriptLoss` confirmation (a small view modifier in
  `Views/Components.swift` taking the count and the action) so the Analyze
  view's re-run menu asks the same question. When the count is zero the action
  runs without a dialog.
- Undo Re-cut: before calling `undoTranscriptRecut`, fetch the backup and the
  current rows and ask only when `TranscriptSpeakerRecut.hasEdits(current,
  beyond: backup)` is true: "Undoing the re-cut throws away n edited lines.
  Undo anyway?".
- `TranscriptionSet` gains `editedCount: Int = 0` (filled in
  `transcriptionSetRows` with a correlated COUNT) for the picker label.

## Out of scope

- Editing timings or splitting/merging lines by hand.
- Editing translation rows directly (they follow the original).
- A merge policy for Team Sync when two Macs edit the same line.

## Verification

- `build-for-testing` in Debug.
- Tests listed per phase; the suite runs in `scripts/release.sh`.
- Live: open the Transcript sheet on a transcribed podcast, Edit, change two
  words in a line, Apply. Then: the Express Transcript pick for that passage
  shows the edited words in the word panel and in the pick label; a rendered
  clip with captions shows the edited words with per-word paging; Compare
  shows the diff; Revert All restores the original and the word panel follows.
  Re-transcribe and Undo Re-cut ask first.


## Implementation results — October 20, 2026

### Review fixes (Claude, same day)

- Team Sync does **not** carry `original_words`: the server's `transcripts`
  table has no such column, and sending it would make PostgREST refuse every
  transcript push. The column stays local. A row pulled from a teammate has
  its `original_text` but no original words, so both revert paths align the
  original text onto the row's current words when `original_words` is NULL
  (approximate clocks, exact text). Adding the server column is a separate
  release with its own migration.
- Undo Re-cut refreshes features and topics only. Translations are timed
  rows; re-translating restored rows beside rows translated after the re-cut
  would show both. The automatic translation runner's follow-up only counts a
  row whose id still exists with other text, so a re-cut during a first
  translation no longer re-translates the whole file.
- A non-forced transcription reuses the stored set only when it is in the
  language asked for (any language when none was asked), so changing the
  footage language and transcribing again still transcribes.
- Typing a line back to the transcriber's text is a revert: the line stops
  counting as edited and gets its original words back.
- The refresh hook takes the set being edited, not only the active set, and
  the sheet passes the set on show.

- **Phase 1 complete:** schema 35 and `original_words` migration/backfill;
  normalized LCS word alignment; transactional batch save/revert-all and edit
  counts; exact original JSON restoration; re-cut and backup preservation;
  Optional `TranscriptRow.originalWordsJSON`; Team Sync and script-state columns.
  Legacy backup JSON without the new field is also realigned when restored.
  Added `TranscriptWordAlignmentTests` and `TranscriptEditingTests`, including
  migration, repeated edits, set-scoped revert-all, and backup compatibility.
- **Phase 2 complete:** `transcriptTextsChanged` clears cached rows, calls
  `TranscriptionService.refreshDerived` on its service actor, and dispatches
  changed row IDs through an `enqueueAutoTranslation` overload into AppJobs.
  It refreshes every existing translated language with `translateBatched`,
  whose existing merge preserves other translated rows. Repeated saves are
  coalesced per source set, and a profile switch clears pending IDs. The sheet
  reloads after translation finishes. The existing automatic runner schedules
  a follow-up if source text changed while the first translation was running.
  Added regression coverage for translated subsets and derived refresh.
- **Phase 3 complete:** default read mode, bordered Edit and Compare toggles,
  visible fields and hover pencil, draft-preserving mode switching, Apply /
  Discard bar, original/edited word diff, edited count/filter, and confirmed
  Revert All. Save and both revert paths call the refresh hook. Translation
  rows are read-only. Added `TranscriptTextDiffTests`.
- **Phase 4 complete:** active-set edit count; count-aware re-transcribe
  confirmation; shared `ConfirmTranscriptLoss` in Components; Undo Re-cut
  checks and counts corrections beyond its backup; picker edit counts.
  Analyze's `rerun(.transcript)` control actually lives in `AIInfoSheet`, so
  the shared modifier is installed there rather than in `AnalyzeView`.
  Explicit re-transcription clears the old pin after success, making the new
  set active as the confirmation promises. Undo Re-cut also refreshes derived
  records and translations after restoring rows.

### Reader audit

Inspected `TranscriptQATrim`, `PodcastHighlightTrim`, `WizardEngine`,
`WizardPodcastBRoll`, `TranscriptSpeakerRecut`, `PodcastAnalysisService`,
`CaptionRenderer` / `CaptionPaging`, `MiniWizardTranscriptRules`, `BuilderQuery`,
and `AnalysisRequest`. Text-producing readers use current `text` / `words` /
`wordsJSON`; none substitutes `original_words` for edited content.
`TranscriptSpeakerRecut` uses edit history only to preserve corrected rows and
compare against backups.

The expected no-change reader audit found one necessary exception: a word
inserted between touching clocks, or at a row edge with no spare time, has a
zero-length clock under the specified alignment rules. Q&A / Express,
Highlights, and Builder word queries now retain those tokens. Q&A includes a
zero-length trailing token at the selected upper edge. If a caption page would
contain only zero-length clocks, paging falls back to proportional timing for
that line instead of dropping its words. Normal timed pages retain word clocks.
The new consumer regression covers the zero-gap and row-edge cases.

### Replacement / restore audit

- Re-transcribe preserves the old set and warns with its edit count.
- Undo Re-cut warns only when `hasEdits(current, beyond: backup)` is true;
  counts include text and speaker corrections beyond that backup.
- Re-cut, Map Speakers Again, and Undo Map preserve edited rows whole;
  `transcriptRecutBase` refuses to replace corrections with its backup.
- Set selection, Pin, and Use automatic preserve each set's edits; picker
  entries show the saved edit count.
- Existing unsaved-draft close / discard behavior remains.
- Cached transcript restoration already reused stored rows. Inspection found
  that a missing disk cache could still cause a non-forced run to create a new
  set. Non-forced plain and podcast transcription now reuse stored rows before
  looking for disk cache files, preserving edits even after cache eviction.
- Team Sync carries both originals; conflict resolution remains out of scope.

### Verification and remaining work

No implementation phase or requested feature was skipped. Tests are written
with Swift Testing, but were not executed, as requested. No Release build, app
launch, commit, or push was performed. Protected files were not changed.

The exact requested compile command was attempted: `xcbeautify` is unavailable
in this environment. Two direct attempts with the same Debug
`build-for-testing` arguments exited 143 (signal 15), before compilation, after
Xcode filesystem/CoreSimulator service access errors. Logs:
`/private/tmp/clipbuilder-transcript-build.log` and
`/private/tmp/clipbuilder-transcript-build-retry.log`.

Fallback validation: all changed Swift files pass `swiftc -frontend -parse`;
word alignment, text diff, caption paging, and the extracted shared confirmation
modifier pass direct Swift type-checking. The extracted attributed-diff
rendering method also type-checks. Full-app direct type-checking is blocked by
`sandbox_apply: Operation not permitted` / macro-plugin errors. These partial
checks do **not** establish a successful application or test-target build.
`git diff --check` passes.

Remaining: run the requested Debug build in an environment with working Xcode
services and xcbeautify; fix any resulting compiler errors, then perform the
live Verification sequence above. Unit tests await the authorized release
workflow (or an explicit request to run them).
