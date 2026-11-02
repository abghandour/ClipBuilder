# Sources analysis flow: type and language changes, step visibility

Date: November 2, 2026. Status: implemented (uncommitted); Codex read-only review in progress.

## Why

A review of the Sources pane found that the analysis pipeline reads a
video's type and language at the moment a pass runs, but nothing tells the
user when a later change made the stored results wrong, and nothing asks
before the first analysis when neither is known. Six defects and five
usability gaps, in order of severity:

1. A user-chosen video language is transcribed without checking that its
   recognizer is installed (only the project's languages are checked), so a
   background pass can hang on a silent asset download.
2. Coverage never compares a run's `AnalysisRequest.videoType` with the
   video's current type: Fight → Interview keeps fight scenes "up to date".
3. Untyped recordings are classified silently (over 5 min) or defaulted to
   the visual pass (under 5 min) before the user is asked.
4. Language detection that finds nothing leaves no trace.
5. `AnalysisStepBatch.partition` names speakers in place before the batch
   that re-transcribes, on the stale transcript.
6. Unfinished or failed runs are not visible in Status.

## Phases

### Phase 1: pure rules (AnalysisCoverage, AnalysisSteps, AnalysisStepBatch)

- `AnalysisCoverage.report` gains `.outdated(stage: "Type changed")` when the
  active run's request type differs from the video's current type (both
  non-nil). Action `.analyze`; message names both types. Checked before the
  exchange rules so a Fight → Interview change asks for a new analysis, not
  for exchanges on fight scenes.
- `.untyped` no longer requires a duration under 300 s: after a run, nil
  type means the classifier failed and the user must choose.
- `AnalysisSteps.missing`: scenes and exchanges count as missing on
  "Type changed".
- `AnalysisStepBatch.partition`: a file whose batch re-transcribes (or runs
  the podcast pass, which maps speakers itself) drops the in-place
  speaker-naming step.

### Phase 2: language guard and detection trace

- `AppStore.requireRecognizers(for video:)` checks the project's spoken
  languages plus the video's resolved transcription language. Used by
  Transcribe, the in-run transcript check and the podcast rerun.
- `VideoLanguagePicker` marks languages whose recognizer is not installed
  ("Spanish — not installed") from a store cache of installed recognizer
  locales refreshed with language readiness.
- Detection that finds nothing stores `language_source = 'detected'` with a
  nil language (the DB setter already accepts that), so the badge can show
  "?" with the reason and detection does not repeat every launch. A user
  choice still overrides; "—" (user, nil) stays silent.

### Phase 3: ask for the type before the first analysis

- Analyze on videos with no type opens a "Set type" sheet listing those
  videos with a type picker each and "Let analysis guess" (keeps today's
  classifier for long recordings, visual pass otherwise). The batch starts
  after the sheet.

### Phase 4: Status column and inspector

- Status shows one chip per expected step for the video's type, in pipeline
  order: People, Scenes or Exchanges, Transcript, Speakers (talking types),
  Score (fight types keep the existing fight cell). Chip state: done
  (secondary, with its count), missing (orange outline), outdated (orange
  with arrow), running (spinner). Clicking a missing or outdated chip runs
  that step. "No people" is a done state distinct from never run.
  Unfinished work shows as an orange warning chip whose click resumes.
- Type and Language are editable in the grid (Type column picker; new
  Language column replacing the badge).
- Inspector: under Type and Language, one line stating the consequence of
  the current mismatch with its button ("Analyzed as Fight; now Interview.
  Analyze again." / "Transcript is English; this video is Portuguese.
  Transcribe again."). The coverage reason and speaker verdict reason are
  shown as text under the analysis batch control, not only in tooltips.

## Result

All four phases are implemented. Pure rules: `AnalysisCoverage` (type
change, untyped after a run), `AnalysisSteps` (type-changed scenes and
exchanges, partition keeps speaker naming out of the in-place pass when
the batch re-transcribes), `AnalysisStepPresentation` (chips and
"steps to run"). Views: `AnalysisStepChips`, `VideoTypePromptSheet`,
editable Type and Language columns (`fillsWidth` on both pickers so the
popup fills its cell), inspector reason lines. Store: `recognizerStates`,
`requireRecognizers(for:)`, failed detection stored as
(nil, detected), `setVideoTypes` awaited before an analysis starts.
Verified live in scratch: chips, the type prompt before Analyze, the
Interview → Fight change marking scenes outdated with the reason line and
Analyze button, the "?" badge for a failed detection. Tests:
AnalysisStepPresentationTests, AnalysisStepsTests, AnalysisCoverageTests,
VideoLanguageTests, TranscriptionLanguageRulesTests.

## Not done

- A "guessed" marker on the type would need a `type_source` column (schema
  45 plus a server sync column). Deferred until a release can ship it.
