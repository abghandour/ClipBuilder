# Word Alignment Plan

Date: 2026-11-09
Status: implemented on main, uncommitted. The model archive is hosted as an extra asset on the v1.157 release. Updated 2026-11-10: the model downloads by itself for a Portuguese project, and Transcribe asks which timing to use.

## Problem

Apple's SpeechTranscriber gives each word a time on a 0.06 s grid, with no gaps between words. A pause is absorbed into a neighbouring word and a word's length is not what is heard. On a hand-marked 12 s Portuguese clip (19 words, 38 boundaries) the median boundary error was 87 ms and the worst 1.6 s. Boundary waveforms, pick and Q&A ranges, captions and cuts all sit on these times.

## Decision

Keep Apple's text. Add an optional second pass that re-times the words against the audio with a CTC acoustic model (forced alignment). The user chooses in Settings → Transcription → Word timing:

- **Apple (standard)**: the recognizer's times, as before. Default.
- **Precise (Portuguese)**: Portuguese transcripts are re-timed after recognition. Other languages keep Apple's times.

Measured on the same marks: loudness snapping 54 ms median (worst 1.06 s), forced alignment 28 ms median (worst 160 ms) as built in the app. Snapping alone cannot fix errors larger than its search window, so it was not built.

## Choosing per transcription (2026-11-10)

- Settings → General → Transcription → **Default word timing** is what a transcription uses when nothing asks: analysis runs, the wizard, the Builder, the "Analyze (N steps)" footer.
- A Transcribe or Re-transcribe the user starts asks which timing to use when there is a choice: the model is installed and the video may be Portuguese (its own language when the user set one, otherwise the project's spoken languages). The default from Settings is the first button. Rule: `WordTimingRules.options`.
- It only asks when speech would actually be recognized. A plain Transcribe of a video that already has a usable transcript keeps that transcript and asks nothing.
- Main window controls (Sources context menu, a single file's Transcript step) go through `AppStore.requestTranscription`; the root view shows the dialog (`TranscriptionModelChoiceDialog`). The Transcript sheet and the AI info sheet ask in their own re-transcribe dialog, one button per timing.
- The model downloads without being asked when the active project speaks Portuguese (`autoInstallWordTimingModelIfNeeded`, at the end of `refreshLanguageReadiness`): once per profile session, never in the test host, never after the user removed it (`WordAlignerAutoInstallOff` user default, cleared by the Download button). A failed automatic download writes a log line, not an alert.

## Model

- `jonatasgrosman/wav2vec2-large-xlsr-53-portuguese`, Apache-2.0 (a fine-tune of `facebook/wav2vec2-large-xlsr-53`, also Apache-2.0). Meta's MMS aligner scored the same but is CC-BY-NC and cannot ship.
- Converted to Core ML by `scripts/models/convert_word_aligner.py`: fixed 20 s input, log-softmax output, 8-bit weights. 302 MB unpacked, 260 MB zipped.
- Runs on CPU and GPU only. At 16-bit precision CPU-only returned NaN, and the Neural Engine did not finish compiling it (both measured 2026-11-09).
- Not bundled. Downloaded on request to `~/Library/Application Support/ClipBuilder/Models/PortugueseAligner-1/`, verified against a pinned SHA-256, compiled on the Mac. `WordAlignerModelURL` (user default) points a build at another copy.
- Hosted at `releases/download/v1.157/PortugueseAligner-1.zip`. It is an extra asset on an app release, not a release of its own: the beta updater takes the newest release and would read a model-only release as an update with no installer.
- Speed: three minutes of audio in about 3 s on the GPU in the Python prototype; not timed in the app.

## How it works

1. `WordAligner.emissions` reads the normalized 16 kHz mono file the recognizer heard, in 20 s windows that advance 16 s. Each window is normalized to zero mean and unit variance and contributes its middle 16 s, so every kept frame had audio on both sides. Result: one row of letter log-probabilities per 20 ms.
2. `CTCForcedAligner.retime` takes the transcript's words in blocks of about 12 s. Each block is aligned together with three context words on each side and 2 s of margin, with a free wildcard at both ends for speech the block does not spell. Only the block's own words are kept, so blocks are independent and an error cannot cascade.
3. A word keeps its recognizer time, clamped between its placed neighbours, when the model cannot spell it (digits), when it barely heard it and would move it more than 0.5 s outside the recognizer's span, or when it would stretch it more than 1 s past the recognizer's length (an abbreviation such as "UFC").
4. Every placed word's end is extended 60 ms, never past the next word: the model stops words about that early on the marked clip.
5. Segment edges follow their first and last word.

## Where it hooks in

- `TranscriptionService.refineTiming` runs after recognition, and when a cached recognizer result is stored into an empty transcript. The transcript cache keeps Apple's times, so the setting can change later.
- A failure in the second pass logs a line and keeps Apple's times. Cancellation still cancels.
- Stored provenance model: `SpeechTranscriber + wav2vec2 word timing`.
- Existing transcripts are not touched. Transcribing a video again re-times it and replaces the transcript, edits included.
- The download is an `AppJobs` job (`.wordTimingModel`), started from the Settings row or by a Portuguese project.

## Not done

- Re-timing an existing transcript in place, keeping its edits.
- Other languages. The same author publishes Apache-2.0 models of the same size for English and Spanish; none is tested.
- A second speaker and clip. Every number here comes from one speaker and one 12 s clip, and the 60 ms tail was tuned on those marks.
