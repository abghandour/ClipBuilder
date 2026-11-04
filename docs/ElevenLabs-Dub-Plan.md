# ElevenLabs voices for the dub

Date: November 3, 2026. Status: implemented November 3, 2026 (phases 1-5); live check pending. Requested by the
user on November 3, 2026: "I want the text-to-speech per line."

## Goal

A third voice engine for the dub, next to Mac voices and Siri voices: each
dubbed line is spoken by an ElevenLabs voice through the ElevenLabs
text-to-speech API. Everything else in the dub stays as it is: the lines
come from the translated transcript (`DubPlanning`), the user hears and
edits every line in the review sheet, the fit, ducking and mixing are
unchanged (`DubPreparation`, `DubMixer`). The dubbed audio is cached like
the other engines' audio so a re-render never pays twice.

Out of scope here: the ElevenLabs Dubbing API (end-to-end dubbing of a
whole clip) and voice cloning. Cloning is a natural follow-up once this
works: an instant clone from a speaker's clean turns, stored on the person.

## Where we stand

- `DubVoiceEngine` (`Services/Dubbing/SiriDubVoices.swift`) has `mac` and
  `siri`; `DubSettings.engine` and `FootageDefaults.dubEngine` store it, the
  Voices menu in `Views/DubLanguagePicker.swift` lists `allCases`.
- `DubPreparation.Speech` is the seam: `voices(language)`, `synthesize(text,
  voice, rate)`, `duration(url)`. `Speech.forEngine` picks the engine. Both
  engines synthesize through `DubSynthesizer.shared.synthesize`, which routes
  Siri identifiers (`com.apple.siri.natural.`) to `SiriDubSynthesizer`.
- `DubSynthesizer.Voice` is `identifier, language, name, quality, gender`;
  `DubLanguageChoices.voices(engine:)` and `languages(voices:)` drive the
  language menu; `DubPreparation.assigningVoices` hands voices out per
  speaker by gender.
- `DubSynthesizer.cacheName(language:voice:rate:text:)` names the CAF in
  the dubs cache; `SiriDubSynthesizer` reuses the rate-1 audio and applies
  the fit rate with ffmpeg `atempo` (`conversionArguments`).
- `LanguageProbe.dubVoice(language, engine)` reports readiness;
  `LanguageReadinessBanner` offers "Open System Settings" when a dub voice
  is not installed.
- The app has no API keys yet: AI providers are command line tools. Secrets
  live in the data-protection keychain (`GoogleDriveKeychain`, `KeychainAPI`
  seam for tests), never in profile JSON, which syncs to the team.
- Long work runs under `AppJobs`; dub synthesis already does.

## ElevenLabs API facts the code relies on

- Base URL `https://api.elevenlabs.io`, header `xi-api-key: <key>`.
- `GET /v1/user/subscription`: `tier`, `character_count`, `character_limit`,
  reset date. Used by the connection check and the credits caption.
- `GET /v2/voices?page_size=100`: `voices[]` with `voice_id`, `name`,
  `category` (premade, cloned, professional, generated), `labels`
  (`gender`, `accent`, `age`, `language`), `verified_languages[]`.
- `POST /v1/text-to-speech/{voice_id}?output_format=mp3_44100_128`, JSON
  body `{ "text", "model_id", "language_code"?, "voice_settings": {
  "stability", "similarity_boost", "use_speaker_boost" } }`, returns the
  audio bytes. Default model `eleven_multilingual_v2` (speaks every
  supported language from the text itself). `mp3_44100_128` is available on
  every plan; PCM output formats are gated by plan, so the MP3 goes through
  ffmpeg into the mixer's 48 kHz float CAF like the Siri AAC does.
- Errors: 401 with `detail.status` `invalid_api_key`, `quota_exceeded`
  (also 401), 429 `too_many_concurrent_requests`, 422 for bad text or voice.
  Concurrency per plan: free 2, starter 3, creator 5, pro 10.
- Billing is per character of text sent. A 60 s clip is a few hundred
  characters. The free plan allows no commercial use.
- Supported languages of the multilingual model (ISO 639-1): en, ja, zh, de,
  hi, fr, ko, pt, it, es, id, nl, tr, fil, pl, sv, bg, ro, ar, cs, el, fi,
  hr, ms, sk, da, ta, uk, ru, hu, no, vi.

## Design

### Key storage and settings

- `Services/ElevenLabs/ElevenLabsKeychain.swift`: the `GoogleDriveKeychain`
  pattern (data-protection keychain, `KeychainAPI` seam), service
  `com.clipbuilder.elevenlabs`, one item `api-key`. The key belongs to the
  Mac, not to a profile.
- `AIConfig.elevenLabs: ElevenLabsSettings?` (`Data/AppSettings.swift`),
  Optional so existing settings JSON decodes: `model` (default
  `eleven_multilingual_v2`), `stability` 0.5, `similarity` 0.75,
  `concurrency` 2. No key in here.
- Settings > AI gets an "ElevenLabs" group (`Views/SettingsView.swift`,
  `AISettingsTab`): a `SecureField` for the key that writes the keychain on
  commit, a "Check" button that calls the subscription endpoint and shows
  "Connected: <tier>, <used>/<limit> credits this month" or the error, a
  "Remove key" button, and the model menu. The check runs in a `.task`
  started by the button, not in a job: it is one short request.

### Client

- `Services/ElevenLabs/ElevenLabsClient.swift`, `nonisolated struct` with an
  injected transport `@Sendable (URLRequest) async throws -> (Data,
  HTTPURLResponse)` (default `URLSession.shared`), so tests never touch
  the network. Methods: `subscription()`, `voices()`, `speak(text:voiceID:
  model:settings:) -> Data`. Maps the error statuses above to
  `ElevenLabsError` (`invalidKey`, `quotaExceeded(remaining:)`,
  `tooManyRequests`, `badRequest(String)`, `http(Int)`), each with a
  `userMessage` that says what to do ("Add your ElevenLabs key in Settings
  > AI", "Your ElevenLabs credits for this month are used up").
- Per-request timeout 60 s. Retries once on 429 after 2 s.

### Voices

- `Services/ElevenLabs/ElevenLabsVoices.swift`, `nonisolated enum`:
  identifier scheme `elevenlabs:<voice_id>` (`isElevenLabs`, `voiceID`),
  `supportedLanguages`, and `voices(from: [ElevenLabsVoice], language:)
  -> [DubSynthesizer.Voice]`: every account voice stamped with the
  requested language (the model speaks any supported language), `quality`
  3, `gender` from `labels.gender` or `DubVoiceGender.inferred(voiceName:)`,
  `name` with the category when it is a clone ("Ana (cloned)").
- The voice list is fetched once per launch and cached in memory by an
  `actor ElevenLabsVoiceCache` with `refresh()`; the picker's Manage
  button and the Settings check refresh it.
- `DubVoiceEngine` gains `elevenLabs` ("ElevenLabs voices"). Raw value
  `elevenLabs`; the enum is `Codable` and synced inside the profile, so a
  teammate without a key sees the readiness error below, never a crash.
- `DubLanguageChoices.voices(engine:)` returns the cache for `.elevenLabs`;
  `languages(voices:selected:)` offers `ElevenLabsVoices.supportedLanguages`
  for that engine (the voices carry no language of their own).
- `DubSynthesizer.Voice.qualityLabel` returns "ElevenLabs" for the prefix.
- `DubLanguagePicker` captions: "<n> ElevenLabs voices", or "Add your
  ElevenLabs key in Settings > AI" with an "Open Settings…" button when the
  key is missing, or the connection error.

### Synthesis

- `Services/ElevenLabs/ElevenLabsDubSynthesizer.swift`, modelled on
  `SiriDubSynthesizer.synthesize(text:voice:rate:directory:)`:
  1. Cache name: `DubSynthesizer.cacheName(language:voice:rate:text:)`
     where `voice` is the identifier plus the model id
     (`elevenlabs:<voice_id>#<model>`), so a model change re-synthesizes
     and a settings change does not disturb Siri or Mac names.
  2. If the rate-1 CAF exists, convert it with `atempo` for rate > 1,
     exactly as Siri does (`SiriDubSynthesizer.conversionArguments`). The
     API is called once per line and text; never twice for a fit.
  3. Otherwise `client.speak`, write the MP3 to a temp file, ffmpeg to the
     48 kHz float CAF, remove the temp file.
  4. Empty text, rate outside 1...1.25 and non-ElevenLabs identifiers throw
     `ScriptError.invalid` like the Siri path.
- `DubSynthesizer.synthesize` routes `ElevenLabsVoices.isElevenLabs(voice)`
  to it before the Siri check. `DubPreparation.Speech.elevenLabs` uses the
  cache for voices and the shared synthesizer; `forEngine` returns it.
- Concurrency: `DubPreparation.synthesize` runs lines through
  `BoundedConcurrency.map` already or sequentially; for ElevenLabs the
  limit is `settings.concurrency` (default 2, the free plan). Cancellation
  from the job's Stop propagates through `Task.checkCancellation` before
  and after the request.
- Logging: the dub job log gets one line per request with the character
  count, and a final "ElevenLabs: N characters" so the user sees the cost.

### Readiness

- `LanguageProbe.live.dubVoice` for `.elevenLabs`: no key → `.missing`
  (title "ElevenLabs key"), language outside `supportedLanguages` →
  `.unsupported`, voices empty → `.missing`, else `.installed`.
- `LanguageReadinessBanner`: when the missing asset is an ElevenLabs voice
  the button is "Open Settings…" (opens Settings > AI) instead of "Open
  System Settings".
- `AppStore+Languages` assistant voice list (`dubVoicesForAssistant`) goes
  through `DubLanguageChoices.voices(engine:)`, so nothing to change.

### Credits caption (last phase)

- `DubReviewSheet` shows "≈ N characters" for the lines not yet cached and,
  when the subscription check succeeded this session, "M credits left this
  month". Text only; synthesis is not blocked.

## Phases

1. Key and settings: keychain, `ElevenLabsSettings`, Settings > AI group,
   client with `subscription()` and the connection check. Tests:
   `ElevenLabsClientTests` (request headers and paths, error mapping from
   fixture JSON through the stub transport), `ElevenLabsKeychainTests`
   (`KeychainAPI` stub, as `GoogleDriveKeychainTests`).
2. Engine and voices: `DubVoiceEngine.elevenLabs`, voice cache, picker
   captions, `DubLanguageChoices` language list. Tests:
   `ElevenLabsVoicesTests` (parsing a voices fixture, gender, identifier
   round trip, language stamping), `DubLanguageChoicesTests` extension.
3. Synthesis: `ElevenLabsDubSynthesizer`, routing in `DubSynthesizer`,
   `Speech.elevenLabs`, concurrency and logging. Tests: cache reuse and
   atempo path with a stub transport that returns a fixture MP3, API called
   once per text, error surfaces as the client's `userMessage`;
   `DubPreparationTests` with `Speech` stubbed, as today.
4. Readiness: probe, banner button, `LanguageReadinessTests` cases.
5. Credits caption in the review sheet.

Each phase ends with `build-for-testing` and the named suites; the live
check (a real key, one English to Portuguese clip through the Express dub)
is done once after phase 3 and again after phase 4.

## Decisions

- Per-line text-to-speech, not the Dubbing API: keeps the transcript, the
  translation and the line review in the app, and costs per character
  instead of per minute of audio.
- Fit rate by `atempo`, never a second API call: deterministic, free, and
  the same path Siri voices use.
- The key is Mac-local in the keychain; the engine choice syncs with the
  profile. A teammate without a key gets a readiness message that names
  Settings > AI.
- MP3 output, converted by ffmpeg: available on every plan, and the mixer
  already expects a converted CAF.

## Not in this plan

- Voice cloning (instant clone from a speaker's turns, voice id stored on
  `PersonRecord`), ElevenLabs Dubbing API, lip sync, speed through
  `voice_settings.speed`.
