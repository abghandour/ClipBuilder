# Dubbing: a spoken translation track for a rendered clip

Date: October 22, 2026. Status: phases 0–5 implemented (Codex) and tested (Claude); phase 6 live English↔Portuguese check pending; phase 7 (Siri voices through Shortcuts) implemented and tested October 22, 2026.

## Goal

A clip whose people speak English can be rendered with a Portuguese voice
track, and the other way round. The dub speaks the translated transcript
line by line, timed to where each line is spoken in the clip, in a voice per
speaker. The original voices are lowered under the dub (not removed, so room
tone, laughs and crowd stay), music is untouched, and captions follow the dub
language. The user hears every dubbed line before rendering and can fix its
text or voice. Lip sync is out of scope.

Requested by the user on October 22, 2026: "if the video is in English I
want to provide a Portuguese dub, and vice versa."

## Where we stand

- Transcripts: `transcripts` rows carry `language`, `is_translation`, start
  and end, text, words, and a speaker attribution (`TranscriptRow.speaker`,
  nil = follow the speaker turns). Translations are rows with
  `is_translation = 1` in the target language, produced on the Mac by Apple's
  Translation framework (`AutoTranslationRunner`, driven by
  `editingDefaults.podcast.autoTranslateLanguage`) or by the model
  (`TranscriptTranslator.translateBatched`, task `.translate`). Captions in a
  language use `Database.transcriptSegments(videoID:start:end:language:)`;
  `WizardEngine.captionSegments` logs when a translation is missing instead of
  silently falling back.
- Speakers: `SpeakerTurn` has `personKey` and `tile`;
  `CropRecipePlanner.tile(for:tiles:)` maps a turn to a feed. People are
  `PersonRecord`s with a key and a name; nothing about voice.
- Render audio: `MultitrackRenderer` assembles segments with each clip's own
  audio (`volume`, `muted`, `speed`), then `buildMusicTrack` /
  `overlayMusicTrack` (around line 2014) lay the sound lane (`SoundItem`,
  music only) over the assembly with the original audio lowered by a
  `volume='between(t,a,b)*level+…':eval=frame` expression and `amix`. The
  caching keys the assembly on the document, so a document field change
  re-renders.
- Jobs: long work runs through `AppJobs` (`AppJobKind`, status bar row with
  Stop, review sheet from the root view). User rule: anywhere a cut or range
  is reviewed the user can play it and drag its ends.
- Voices on the Mac: `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders
  an utterance to PCM buffers offline, with `AVSpeechSynthesisVoice` per
  language (`pt-BR`, `en-US`, …), rate and pitch. Enhanced and Premium voices
  are downloaded by the user in System Settings > Accessibility > Spoken
  Content; the app can list what is installed. No AI provider in the app
  produces audio: the CLIs (Claude, Gemini, Antigravity, Codex) are text and
  image only, and the app keeps no cloud API keys (Keychain holds Drive,
  Instagram and Team Sync sessions only).

## Decisions

Confirmed by the user on October 22, 2026. Also requested then: dubbing and
its language choice live in AI Wizard Express, on the Audio tab next to Music.

1. Voices come from the Mac's speech synthesizer first. No account, no cost,
   offline, same for every teammate. A cloud voice service with voice cloning
   (ElevenLabs or similar) is a later phase behind its own key, because it
   needs new credential and HTTP code and per-person consent to clone.
2. The original speech is lowered to 15 % under each dubbed line with 0.15 s
   ramps, not muted. A "Replace original speech" switch mutes it fully for
   people who prefer a clean dub.
3. A line that runs long is sped up to at most 1.25× by the synthesizer, then
   stretched by at most 1.15× in ffmpeg; beyond that it may run up to 0.6 s
   into the following silence, and the review marks it "tight" so the user
   can shorten the text. Portuguese runs about 15–20 % longer than English.
4. One voice per speaker, chosen from installed voices of the dub language,
   remembered per person in the profile. Unknown speakers share one voice.
5. Dubbing is a property of the timeline document (what gets rendered), with
   a per-profile default language so the wizard and Express can dub every
   clip they make.

## Rules

- Nothing is dubbed without a translation. The dub job first ensures the
  target language rows exist for the clip's ranges: installed Apple
  Translation first (`TranscriptTranslator.translateInstalled`), the model
  second (`translateBatched`, visible in the AI details as task
  `translate`). If neither can, the job stops with "No <language> translation
  for <file>; translate the transcript first" rather than dubbing the
  original text.
- Lines come from the clip's source range: translation rows whose span lies
  inside `[sourceStart, sourceEnd]`, placed on the timeline at
  `clip.startTime + (row.start - sourceStart) / clip.speed`, clipped to the
  clip. Muted clips, cutaways and bumpers get no lines. A row cut by a clip
  edge is dropped when less than 40 % of it remains, else trimmed to the
  words that fit (word timings when present).
- Speaker: the row's attribution when set, else the speaker turn covering
  the row's midpoint, else "unknown". Each speaker key maps to a voice.
- Synthesis runs off the main actor in an actor, one utterance per line,
  written to CAF in `data/.cache/dubs/<sha256(language, voice, rate, text)>.caf`
  and reused. The job reports per-line progress.
- Fit: measure the file. The slot is the line's own span plus the silence
  before the next line (capped at 0.6 s). Over the slot → re-synthesize at the
  rate that fits, up to 1.25×; still over → `atempo` up to 1.15×; still over →
  keep, mark tight.
- Mix: one dub track for the whole timeline (silence plus `adelay`ed lines,
  `amix`), overlaid after assembly and before the music pass, lowering the
  original audio to the chosen level during each line with ramps, in the same
  shape as `overlayMusicTrack`. Music ducking stays as it is. The dub track is
  part of the document hash so caches invalidate.
- Captions: when a dub language is set and captions are on, the caption
  language defaults to the dub language; the user can still pick another.
- Review before render: the job ends in the root review sheet listing every
  line with speaker, voice, text (editable), timing, a play button that plays
  the dubbed line over the clip's video, and a "tight" badge. Editing text
  re-synthesizes that line only. The render reads the reviewed lines.
- Every control is visible: Builder toolbar "Dub…", Inspector section "Dub"
  on the timeline, Audio step of the wizard and Express. No context-menu-only
  entry.
- New stored properties are Optional. Pure logic (line placement, fit maths,
  filter strings) lives in `nonisolated` enums with tests; only the
  synthesizer actor and the mixer touch AVFoundation and ffmpeg.
- No option is labelled AI unless a model call happens: the on-device
  voices are "Mac voices"; the model shows up only for translation.

## Model

- `Data/Dubbing.swift`
  - `struct DubSettings: Codable, Sendable, Equatable { language: String;
    voices: [String: String] (speaker key → voice identifier);
    originalLevel: Double = 0.15; replaceOriginal = false; enabled = true }`
  - `struct DubLine: Codable, Sendable, Identifiable { id: UUID; clipUID: UUID;
    speakerKey: String; voice: String; text: String; sourceStart, sourceEnd;
    start, duration (timeline); rate: Double; stretch: Double; tight: Bool;
    audio: String? (cache file name) }`
  - `TimelineDocument.dub: DubSettings?` and `TimelineDocument.dubLines:
    [DubLine]?` (both Optional; existing JSON decodes).
  - `WizardOptions.dubLanguage: String?`; `FootageDefaults.dubLanguage: String?`
    (profile default); `ProfileEditingDefaults.dubVoices: [String: String]?`.
- `Services/Dubbing/DubPlanning.swift` (pure): `lines(document:, rows:,
  turns:, settings:)`, `slot(for:next:)`, `fit(duration:slot:) -> (rate,
  stretch, tight)`, `duckExpression(lines:level:ramp:)`.
- `Services/Dubbing/DubSynthesizer.swift` (actor): `installedVoices(language:)`,
  `synthesize(text:voice:rate:) -> URL` with the cache, `duration(of:)`.
- `Services/Dubbing/DubMixer.swift`: `buildTrack(lines:duration:output:)` and
  `overlay(video:track:lines:settings:output:)` as ffmpeg runs, using
  `FFmpeg.run` like the music functions.
- `AppJobKind.dub`, `AppStore+Dubbing.swift`: `dubTimeline(language:)` runs
  translation check → lines → synthesis → fit → review; `applyDubReview`.
- `MultitrackRenderer`: after assembly, when `document.dub?.enabled == true`
  and `dubLines` exist, mix the dub track; missing cache files are
  re-synthesized through the synthesizer before the render starts (same
  cache key, so the output is the same).
- Views: `Views/Builder/DubInspector.swift` (section), `Views/DubReviewSheet.swift`
  (lines with play, edit, voice), toolbar button in the Builder, Audio step
  rows in `WizardOptionsSteps` / Express.

## Phases

0. Model and settings. `DubSettings`, `DubLine`, Optional document fields,
   profile defaults, `AppJobKind.dub`. Tests: decoding old documents, round
   trip.
1. Pure planning. `DubPlanning.lines` from rows, turns and clips (speed,
   trims, muted clips, cutaways, bumpers, 40 % rule, word trimming);
   `slot`, `fit` (1.25× then 1.15×, tight flag), `duckExpression`. Tests for
   each rule, including a Portuguese line 20 % longer than its slot.
2. Synthesis. `DubSynthesizer` with voice listing, cache, duration; a smoke
   test that skips when no voice of the language is installed. Translation
   gate through `TranscriptTranslator`, with the exact message when none.
3. Mix and render. `DubMixer` filter strings tested as strings; render
   integration after assembly; `compareDecoded`-style test that a dubbed
   render has the dub energy in the line windows and the original lowered
   (compare audio, not bytes).
4. Builder UI and review. Toolbar "Dub…" opens a small sheet: language
   (installed translation languages first), voice per speaker, original
   level, replace switch; Start runs the job; status bar row with Stop; the
   review sheet lists lines with play, edit, voice, tight badge; Apply writes
   `dubLines`; Render uses them. Inspector "Dub" section shows the state and
   a "Review lines…" button.
5. Express and the wizard. Express first: on the Audio tab of
   `MiniSettingsCard` (`audioRows`, beside the Music row) a "Dub" toggle and,
   when on, a "Language" picker listing the languages the Mac can speak
   (`DubSynthesizer.installedVoices` languages, Portuguese (Brazil) and
   English first) with a caption naming the voice count and "Install more
   voices in System Settings › Accessibility › Spoken Content" when none.
   `MiniWizardSettings.dub: Bool` and `dubLanguage: String?` with CodingKeys
   and `decodeIfPresent`, `MiniWizardMemory.Field.dub/.dubLanguage`,
   `WizardPresetBridge` fields, the `MiniWizardFlow` summary chip
   ("Portuguese dub"), and `MiniWizardSettings.wizardOptions` →
   `WizardOptions.dubLanguage`. Express keeps its own keys and never reads
   `wizard.*` defaults (user rule). The Audio tab must be offered for
   conversational footage too, not only fight and training: check
   `MiniWizardFlow.effectiveSettingsTab` and the tab list. The Express run
   synthesizes the dub for each rendered clip before its render, inside the
   existing job, and its review shows the dubbed lines with play buttons
   before the render starts (Express phase order in `MiniWizardRun`). Then the
   full wizard: "Dub to <language>" in its Audio step with the same
   `dubLanguage`. Captions default to the dub language in both; the AI details
   list the translation task when the model translated.
6. Live check. Tanner Boser Interview (English) → Portuguese on one 40 s
   scene: two voices, lines land on the speakers, original lowered, captions
   in Portuguese. A Portuguese podcast → English the same way. Listen for
   tight lines and ramps; measure job time per minute of speech.
7. Optional, later. Cloud voices with per-person voice cloning behind a
   provider key in the Keychain, selectable per speaker; the plan's model
   needs no change since a voice is a string.

## Open questions

- Which Portuguese: pt-BR by default (the profile's existing translation
  language is pt-BR); pt-PT voices exist too.
- Overlapping speech (two people at once) gets two lines at once; the first
  phase keeps both and marks them tight.
- Whether the dub should also go out as a separate audio file for Instagram's
  own dubbing or subtitles: not in this plan.

## Already-analyzed videos

No re-analysis. Videos without a translation in the dub language get one
when the dub job runs (installed translation or model), stored as transcript
rows like today's automatic translations.

## Phase 7: Siri voices (added October 22, 2026)

macOS never lists Siri voices to a third-party process: `AVSpeechSynthesisVoice.speechVoices()`
returns none inside the app (the `swift` interpreter does list them because it runs inside
Apple's compiler, a false positive), and `say -v <siri id>` silently falls back to the default
voice. The Shortcuts app is Apple-signed and its "Make Spoken Audio from Text" action offers the
Siri voices, so the app speaks each line through a shortcut.

- `DubVoiceEngine` (`.mac` / `.siri`) is a profile default (`FootageDefaults.dubEngine`, key
  `dub_engine`) chosen in the Voices picker that `DubLanguagePicker` shows in the Builder Dub
  sheet, Express Audio tab and full wizard. `DubSettings.engine` records it per dub.
- `SiriDubVoices` finds downloaded voices by scanning the Siri text-to-speech asset catalog
  (`com.apple.siri.tts.voice.<lang>.<name>.natural.premium` under /System/Library/AssetsV2),
  maps them to `com.apple.siri.natural.<Name>`, and treats a voice as ready when the shortcut
  "Clip Builder Dub <Name>" is in `shortcuts list`. `DubPreparation.Speech.forEngine(.siri)`
  lists only ready voices; the Siri engine with no ready voice fails with a setup message.
- `SiriDubSynthesizer` runs `/usr/bin/shortcuts run "Clip Builder Dub <Name>" --output-path`
  with the text on stdin (the shortcut's only parameter is Shortcut Input; dictionary input,
  `--input-path`, and variable voice/rate parameters all produced nothing), then ffmpeg converts
  the AAC to the 48 kHz float CAF in the shared dub cache, applying the fit rate with `atempo`.
  `DubSynthesizer.synthesize` routes Siri identifiers there, so the renderer's cache restore and
  the review sheet need no changes. About one second per line.
- Setup on a new Mac: `SiriDubSetupSheet` (opened automatically when Siri is chosen with no
  ready voice, or with Manage…) checks ffmpeg (installs through the existing tools job), the
  voice download (opens System Settings › Accessibility › Spoken Content with the path to the
  per-language Siri download), and each voice's shortcut. "Add shortcut" opens a bundled signed
  `.shortcut` when the release ships one (`scripts/sign_siri_shortcuts.sh`, which needs a Mac
  signed into iCloud because Shortcuts refuses unsigned imports), otherwise opens Shortcuts on a
  new shortcut and lists the five manual steps. The sheet re-checks every three seconds.
- Tests: `SiriDubVoicesTests` (asset parsing, readiness, shortcut definition, ffmpeg arguments,
  setup failure) plus two live tests that run only when a ready Siri voice exists.
