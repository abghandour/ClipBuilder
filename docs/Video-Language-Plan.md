# Video language

Date: November 2, 2026. Status: implemented November 2, 2026 (Claude), Codex
read-only review pending. Requested by the user on November 2, 2026.

## What the user asked for

Every video carries a language. Sources shows a two-letter badge ("EN",
"PT") at the far right of the File column, and the detail pane has a
Language dropdown so the user can change it. The app detects the language
when it can.

## Design

- `videos.language` (BCP-47 locale id such as `pt-BR`, nullable) and
  `videos.language_source` (`user`, `transcript`, `detected`, nullable).
  Schema 44 adds both and backfills `language` from each video's original
  transcript. `VideoRecord.language` / `languageSource` are optional, so
  existing JSON decodes unchanged.
- Resolution, in order: the user's choice; the original transcript's
  language, stamped whenever an original transcript is saved unless the user
  chose one; a detection pass over the first minute of audio
  (`TranscriptionService.detectLanguage`, the sampler that podcast
  transcription already used, now shared). Detection runs as the
  `AppJobs` job "Detect Languages" (status-bar row with Stop) for every
  present video with no language, once per video per app session, started
  after the library loads. A sample below 40 % confidence stores nothing.
- Transcription uses the video's language before the project's spoken
  languages (`ProjectLanguageResolver.transcriptionLanguage(for:)`).
- Sync: `language` and `language_source` join the `videos` sync columns;
  server migration `20261102120000_video_language.sql`, schema_version 10,
  `SyncEngine.understoodSchemaVersion` 10. The server migration must be
  applied before the release that ships this.
- UI: `VideoLanguagePicker` (menu, "—" plus common languages, the project's
  spoken languages and the current value) in the detail pane under Type;
  `LanguageBadge` as the last badge in the Sources File column. Pure helpers
  in `Data/VideoLanguage.swift` (choices, badge text, display name).

## Out of scope

Per-video languages in Express/Builder captions; translating the badge
list; detection on Macs without any installed recognizer (the job logs and
moves on).
