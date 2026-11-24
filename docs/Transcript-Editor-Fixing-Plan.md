# Transcript editor: search, doubtful words, speaker pills, speaker filter

Date: 2026-11-14
Status: implemented 2026-11-14 (commit de38ec1, released in 1.165), reviewed by Codex, its eight findings fixed; the AI Proofread call has not run live yet.

Mockups: `docs/mockups/transcript-editor-fixing/` (1 search and pills, 2 speaker
filter, 3 doubtful word fix, 4 replace and apply, 5 automatic proofread).

## Goal

Express Transcript is for choosing passages. Everything that fixes what the
transcript says or who says it lives in one place: the Transcript editor sheet
(`Views/TranscriptSheet.swift`, opened from Raw Videos, Scenes and the Express
Footage card).

The Express Transcript flow work (phases 1, 2, 3 and 6 of
`Express-Transcript-Flow-Plan.md`) was shelved on 2026-11-14 because the
selection screen became too complicated. It is in
`stash@{0}` ("express-transcript-flow phases 1-3+6"), including that plan and
its mockups. Express is back to what 1.164 ships. This plan reuses the stash's
pure rules and storage changes and none of its Express views.

## What the editor has today (1.164)

- Lines, Q&A and Topics views; a Show menu (all, edited, by tag, changed by
  Fix Speakers); language pills; Group by speaker.
- Edit Text mode: every line becomes a text field, changes are held as drafts,
  Apply writes them at once, Discard drops them. "Show what changed" diffs a
  line against the transcriber's text.
- A speaker menu per line (this line, or all lines by that speaker), Fix
  Speakers, Cleanup Cuts, Tools.
- No text search. No per-word confidence is stored, so nothing can be marked as
  doubtful. No way to see one speaker's lines only.
- The speaker name is coded as a coloured capsule, but it sits inside a
  borderless `Menu` label, and macOS draws that label as plain text. The
  screenshot shows the result: a bold white name and no pill. A line that
  continues the previous speaker shows only a small person icon.

## Proposal

### A. Find row

A second row under the toolbar, shown in the Lines view. The toolbar is already
at its width limit (it has a compact variant), so nothing new goes into it.

```
[ magnifier  Find in transcript        3 of 17  <  > ]  [ Replace... ]     Speaker: (All) (Marcello 81) (Alice 79) (Unknown 2)     Doubtful 12  <  >
```

Every text in the row is `lineLimit(1)` plus `fixedSize`; the speaker pills
fall back to one menu through `ViewThatFits` when they do not fit.

### B. Text search

- Field in the find row; Command-F focuses it, Return and Command-G go to the
  next match, Shift-Command-G to the previous, Escape clears.
- Matches in the spoken text and in the translations currently shown, ignoring
  case and diacritics ("patrocinios" finds "patrocínios").
- Each match is highlighted in the text; the current one is stronger, and its
  line scrolls into view (the sheet already has `scrollTarget`).
- Search runs over the lines on show, so it combines with the Show menu and the
  speaker filter. It does not hide lines: the lines around a match are the
  context needed to judge it.
- Typing while in Q&A or Topics switches to Lines.
- Replace: a small strip under the find row with the replacement, Replace (the
  current match), Replace All (count shown), and "Always fix this" which adds
  the pair to the profile's corrections (section D). Replacement matches whole
  words only, with the stash's `TranscriptCorrectionRules` token rules, so
  "cat" never changes "cat's". Spoken text only; translations are re-translated
  on Apply the way they are for any text edit.

### C. Speaker pills and the speaker filter

- The line's speaker is drawn with the shared `SpeakerPill` colours on every
  line, also when it repeats the speaker above (ungrouped view). Grouped view
  keeps one pill per block.
- The pill stays the control that opens the speaker menu. The menu is rebuilt
  so its label keeps the pill look (see "Not verified").
- A pending speaker change keeps its orange pill; a hand-set speaker keeps its
  checkmark; "Speaker?" stays grey.
- Speaker filter: the pills in the find row. All is the default; clicking a
  speaker shows only that speaker's lines, clicking it again or All shows
  everyone. One speaker at a time. Each pill carries the line count. Unknown is
  a pill when any line has no speaker.
- The filter uses the same label the line shows, including an unapplied
  speaker change. It combines with the Show menu and search. It is not saved.
- With a speaker filter on, the status text in the title bar says
  "79 of 162 lines".

### D. Doubtful words and fixing them

What counts as doubtful:

1. The transcriber's own confidence for the word is under 0.5 (one named
   constant), and the word has not been edited or marked right.
2. The AI proofreader suggested another word for it (section E).

Storage, taken from the stash unchanged:

- `TranscriptWord` gains `confidence: Double?`, inside the existing words
  JSON. No schema change and no new Team Sync column.
- `TranscriptionService` stores Apple's per-word confidence, which it reads
  today and throws away.
- `TranscriptWordAlignment` keeps the confidence of a word it keeps and gives
  nil to a word it creates.
- Marking a word right stores confidence 1.0.

Transcripts made before this ships have no confidence. They show no underlines
until they are transcribed again (a new version from the version menu) or
proofread (phase 4). The "ALICE pereira interview" version in the screenshot is
one of these.

In the sheet:

- A doubtful word has a dotted underline in the spoken text, in read mode.
  Translations are never underlined.
- Clicking it opens a fix strip directly under that line: the word in a text
  field, the proofreader's suggestion as a one-click choice when there is one,
  and Fix, Fix All (count of the same word in this transcript), Always Fix
  This, Mark Right, and a play button that plays two seconds around the word.
- The "Doubtful 12 < >" stepper in the find row walks through them in order and
  opens each one's strip, so the whole review can be done from the keyboard
  (Return = Fix, Command-Return = Mark Right, Tab to next).
- Show menu gains "Doubtful words (N)".
- A word that is not doubtful is fixed with Replace (section B) or Edit Text.
  Words are not all clickable: the text stays selectable and copyable.

How a fix is saved: it goes into the sheet's existing drafts. The line turns
orange, the edit bar shows "Apply 3 Changes", Apply writes through the existing
line editor (which keeps the transcriber's original, re-aligns the word times
and re-translates), Discard drops it. Mark Right is held the same way and
written on Apply. One save path, and Undo line, Show what changed and Revert
keep working without new code.

Corrections list, taken from the stash:

- Per-profile `transcriptCorrections` on `BrandProfile` (Optional, local, not
  in the team profile document).
- Tools menu gains "Corrections..." to see, add and delete the pairs.
- New transcriptions apply the list when the lines are stored.

### E. AI Proofread (decided by the user, 2026-11-14)

- Proofread starts by itself right after a video is transcribed for the first
  time. It is a background job (`AppJobs`): a status-bar row with Stop, and a
  progress line in the editor if it is open. It never changes text; it only
  marks words and proposes replacements.
- It runs once per video automatically. A new version made later, or a
  transcript made before this ships, is proofread from "Proofread" in the Tools
  menu ("Proofread Again" when it has already run).
- The transcript is sent as text in bounded parts with the speaker names and
  the profile's corrections list, using the stash's `TranscriptProofreading`
  (prompt, chunking, validation of every suggestion against the current rows).
- Because it runs before the editor is opened, suggestions are saved, not held
  for the session as the stash did: an Optional `suggestion` (replacement and
  reason) on the word inside the words JSON, cleared when the word is fixed,
  marked right or edited. No schema change and no new Team Sync column.
- A failed or stopped proofread leaves the transcript as it was and says so in
  the status bar; it never blocks transcription, translation or analysis.
- Decided 2026-11-14: the switch is a project setting, "Proofread new
  transcripts" in the project's Languages and Transcripts sheet, on by default
  (`ProjectLanguages.proofreadNewTranscripts`, nil means on). The provider is
  the one chosen for "Transcript proofreading" in AI settings.

## Phases

| Phase | What ships | Storage | Size |
| --- | --- | --- | --- |
| 1 | Find row, search with highlight and next/previous, speaker pills on every line, speaker filter | none | Small |
| 2 | Replace, Replace All, corrections list in Tools, applied to new transcriptions | `transcriptCorrections` on `BrandProfile` (Optional) | Small |
| 3 | Stored confidence, dotted underline, fix strip, Doubtful stepper and Show filter, Mark Right | Optional `confidence` in words JSON | Medium |
| 4 | Proofread as a background job (`AppJobs`), started automatically after a first transcription and by hand from Tools; suggestions shown as blue doubtful words | `.proofread` in `AITask` and `AICatalog`; Optional `suggestion` in words JSON; Optional profile setting | Medium |

Phases 1 and 2 are useful on every existing transcript. Phase 3 shows nothing
on a transcript until it is transcribed again; phase 4 is what makes underlines
appear on existing ones.

## Where the code goes

New, each a `nonisolated enum` under `Services/` with a test next to it:

- `TranscriptSearchRules`: folded matching, match ranges per row, next/previous
  with wrap, counts. Phase 1.
- `TranscriptLineFilter`: tag filter, speaker filter and doubtful filter
  composed in one place, replacing the body of `visibleRows`. Phase 1.
- `TranscriptWordRules`: word identity by row id and stored word index (never a
  text search, so a repeated word is still the right occurrence), doubtful
  test, replace one token, Mark Right. Ported from the stash's
  `ExpressTranscriptWordRules` and `ExpressTranscriptReviewRules` under a
  neutral name. Phase 3.

Views, new files so `TranscriptSheet.swift` (2,008 lines) does not grow:

- `TranscriptFindRow.swift`, `TranscriptReplaceStrip.swift`,
  `TranscriptWordFixStrip.swift`, `TranscriptCorrectionsSheet.swift`.
- `TranscriptSheet.swift` gets the state (`searchText`, `currentMatch`,
  `speakerFilter`, `fixingWord`), the row in `editableBody`, and
  `originalText(_:)` building an `AttributedString` with search highlights and
  doubtful underlines. Add a `// MAP` comment at the top; it crosses 2k lines.

Restored from `stash@{0}` as they are (with their tests):

- `Services/TranscriptCorrectionRules.swift`
- `Services/TranscriptProofreading.swift` (phase 4)
- `applyTranscriptCorrections` from `Data/Database+TranscriptCorrections.swift`
- The `confidence` hunks in `Data/Models.swift`,
  `Services/TranscriptionService.swift`, `Services/TranscriptWordAlignment.swift`
- The `transcriptCorrections` hunk in `Data/BrandProfile.swift`
- The `.proofread` hunks in `Services/AITask.swift` and `Data/AppSettings.swift`
  (phase 4)

Left in the stash: every `ExpressTranscript*` view and rule file not named
above, the `MiniWizard*`, `MiniTranscript*`, `RangeReview*`, `KeptClipsPlayer`
and `MiniUndo` changes, join rows, sort, narrative and the Before Generate
checks.

## Decisions (user, 2026-11-14)

1. Fixes wait for Apply.
2. AI Proofread is in, runs automatically after a first transcription, and is
   switched per project.
3. A speaker pill on every line.
4. Still open: what happens to the stash: keep it as the parts bin for this plan
   (recommended until phase 4 is done), or also bring some Express piece back
   later (sort by time, join rows)?

## As built, where it differs from the text above

- The Doubtful stepper sits left of the speaker pills, so the pills do not
  move when the last doubtful word is decided.
- The profile's corrections are applied to a new transcription before it is
  stored, not through the line editor: the line is not marked edited, so Fix
  Speakers can still split it. The uncorrected word is not kept.
- Fixing words is off while Apply is writing and while Fix Speakers runs.
- The recognizer's confidence is stored capped at 0.99; exactly 1 means the
  user marked the word right.
- Marks (marked right, suggestions) are carried by word position when a save
  is a list of word fixes, and by word time when the transcriber's rows come
  back over a re-cut.
- The two mockup files named `TranscriptReplaceStrip.swift` and
  `TranscriptCorrectionsSheet.swift` live inside `TranscriptFindRow.swift` and
  `TranscriptWordFixStrip.swift`.

## Not verified

- That a `Menu` with a plain button style keeps the coloured pill label on
  macOS 26 and 27. If it does not, the pill becomes a plain button that opens
  the same choices in a popover.
- That an `AttributedString` link inside a selectable `Text` can carry the
  dotted underline and deliver the click to the sheet. If link styling wins
  over the underline, the doubtful words of a line are drawn with the word
  layout `TranscriptQAWordPanel` already uses, for lines that have any.
- That Apple's per-word confidence is useful in Brazilian Portuguese at 0.5.
  The stash stored it but it was never looked at live. Phase 3 starts by
  transcribing one real video and reading the numbers before any UI is built.
- An older app version on the team that rewrites a line's words JSON will drop
  the confidence field for that line. Harmless (the underline disappears), but
  it means confidence is best-effort across a mixed team.
- Search cost on a long transcript (a two-hour podcast is about 2,500 lines):
  the match list must be computed once per query off the main actor, not per
  row while scrolling.
