# Project languages and language readiness

Date: November 1, 2026. Status: implemented November 1, 2026 (Release 1.142), Codex-reviewed, findings applied; server migration applied. Requested by the user
on November 1, 2026 after a teammate ran Transcribe and got no transcript.

## What the user asked for

A way to make sure a teammate's Mac has every language the work needs. The
languages a project uses are defined per project and shared with the team
through Team Sync. The app checks the Mac against that list, installs what it
can, and says clearly what it cannot.

## What exists today

- Languages are per profile, not per project: `FootageDefaults.language`
  (the single transcription language, "" = auto-detect), `dubLanguage`,
  `BrandProfile.captionLanguages`, and `PodcastSettings.autoTranslateLanguage`
  (`Data/AppSettings.swift`). Profiles already sync with the team.
- Transcription reads the profile language at 21 call sites (grep
  `footage.language`): `AppStore+AITools.transcribe`, the analysis step batch
  (`AppStore+Analysis`, `AppStore+AnalysisRequests`), the wizard pipeline,
  the Builder prerequisite context, `DispatchPlanSheet`, `WizardSheetModel`,
  `BuilderWizardLibrary`. A profile-wide language is wrong for a team whose
  projects mix languages, and the wrong language is one of the two causes of
  the empty transcript fixed in 1.141.
- Three on-device assets depend on language:
  1. Speech recognizer models. `SpeechTranscriber.supportedLocales` and
     `installedLocales` report state; `AssetInventory.assetInstallationRequest(supporting:)`
     plus `downloadAndInstall()` fetches a model. `TranscriptionService.runSpeechTranscriber`
     already does this on demand, silently, inside the run.
  2. Translation language packs. `LanguageAvailability().status(from:to:)`
     reports `.installed`, `.supported` (downloadable) or `.unsupported`;
     `TranscriptTranslator` skips pairs that are not installed, so a missing
     pack silently produces no translation. A download is triggered by
     presenting `TranslationSession` work through `translationTask` (the
     system prompts), which only a view can do (`Views/AutoTranslationRunner.swift`).
  3. Dub voices. `DubSynthesizer.installedVoices(language:)` (Mac voices) and
     `SiriDubVoices.readyVoices(language:)` (Siri voices through Shortcuts).
     Neither can be installed by the app.
- `projects` syncs with columns name, created_at, last_opened_at, archived,
  is_home (`Services/TeamSync/SyncTable.history`). The server table was
  created by `supabase/migrations/20261101120000_projects_highlights.sql`.
  Any column added to the sync list must exist on the server first or every
  push of the table is rejected. `SyncEngine.understoodSchemaVersion` is 8.
- Local schema version is 42 (`Database.schemaVersion`); migrations run in
  the `stamped < N` block of `Database.migrate`.

## Design

### Project languages

A project carries `ProjectLanguages`:

```swift
nonisolated struct ProjectLanguages: Codable, Sendable, Hashable {
    /// BCP-47 locale ids spoken in the footage, e.g. ["en-US", "pt-BR"].
    /// Empty = auto-detect, as today.
    var spoken: [String] = []
    /// Caption and transcript translation targets, language codes ("en", "pt").
    var captions: [String] = []
    /// Dub target locales, e.g. ["pt-BR"]. Empty = no dubbing.
    var dub: [String] = []
}
```

Stored as `projects.languages_json TEXT` (nullable; nil = inherit the
profile's values, which keeps every existing project and every existing JSON
decoding unchanged). Synthesized decoding; every new stored property is
Optional or has a default.

Resolution, in a pure `nonisolated enum ProjectLanguageResolver`:

- `resolve(project: ProjectLanguages?, profile: BrandProfile) -> ProjectLanguages`
  fills each empty list from the profile: `spoken` from
  `editing.footage.language` (one entry when set), `captions` from
  `captionLanguages` plus `podcast.autoTranslateLanguage`, `dub` from
  `footage.dubLanguage`.
- `transcriptionLanguage(for video:, languages:) -> String`: the single
  locale passed to `transcribeForVideo`. One spoken language → that locale.
  Several or none → "" (auto-detect, which today samples en-US and pt-BR then
  installed locales). Phase 4 extends auto-detect to sample the project's
  spoken languages first.

### Readiness

A pure `nonisolated enum LanguageReadiness` with an injected probe so tests
run without Speech or Translation:

```swift
nonisolated struct LanguageAsset: Hashable, Sendable, Identifiable {
    enum Kind: String { case recognizer, translation, dubVoice }
    enum State: String { case installed, downloadable, unsupported, missing }
    var kind: Kind
    var language: String          // locale id or "en→pt" for translation pairs
    var state: State
    var id: String { "\(kind.rawValue):\(language)" }
}

nonisolated struct LanguageProbe: Sendable {
    var recognizer: @Sendable (String) async -> LanguageAsset.State
    var translation: @Sendable (String, String) async -> LanguageAsset.State
    var dubVoice: @Sendable (String, DubVoiceEngine?) async -> LanguageAsset.State
    static let live: LanguageProbe   // Speech, Translation, DubSynthesizer/SiriDubVoices
}

nonisolated enum LanguageReadiness {
    /// Every asset the resolved languages need, in display order.
    static func assets(for languages: ProjectLanguages, dubEngine: DubVoiceEngine?,
                       probe: LanguageProbe) async -> [LanguageAsset]
    static func missing(_ assets: [LanguageAsset]) -> [LanguageAsset]   // state != .installed
    static func summary(_ assets: [LanguageAsset]) -> String?            // nil when ready
}
```

Translation pairs: every `spoken` language code × every `captions` code where
the codes differ. Recognizers: every `spoken` locale. Dub voices: every `dub`
locale with the profile's `dubEngine`.

Only the recognizer and translation assets are installable. `downloadable`
recognizers install through `AssetInventory`; `downloadable` translation pairs
install by presenting a `translationTask` with an empty request in the
readiness banner's view (the system shows its download sheet). Dub voices and
`unsupported` entries show an explanation and an "Open System Settings"
button (`x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent`
for voices; the Siri route is documented in `SiriDubVoices`).

### Where it shows

- Project card on the Projects home (`ProjectCardView`): a small language
  row (flags are not used; `Locale.current.localizedString(forIdentifier:)`
  names) and a warning badge when anything is missing on this Mac.
- Sources page (`AnalyzeView`) toolbar area: a one-line banner
  "Portuguese (Brazil) recognizer and English→Portuguese translation are not
  installed on this Mac" with **Install** (runs an `AppJobs` job of kind
  `.languageAssets`, status-bar row with Stop) and **Languages…** (opens the
  editor). Banner text is `lineLimit(1)` + `fixedSize` or `ViewThatFits`.
- The project Languages editor is a sheet opened from the card's menu, the
  Sources banner, and Project settings (every entry point also exists as a
  visible control, never context-menu only). Lists for spoken, captions and
  dub with pickers populated from `SpeechTranscriber.supportedLocales`,
  common language codes, and `DubLanguageChoices.languages`.
- Transcribe, Analyze and the Wizard pipeline check readiness before
  starting. A missing recognizer for a required spoken language stops with
  the message and the Install action instead of downloading mid-run. A
  missing translation pack or voice does not block; it is reported in the
  log as today, plus the banner.

### Sync

- Client: `languages_json` joins `SyncTable.history` "projects" columns.
  Local-only columns stay local. `SyncMapping.isLocalField` strips keys ending
  in path/paths; `languages_json` passes.
- Server: `supabase/migrations/20261101180000_project_languages.sql`:
  `ALTER TABLE public.projects ADD COLUMN "languages_json" text;` Apply via
  the Management API query endpoint (the CLI push times out on the hotspot)
  and insert the version into `supabase_migrations.schema_migrations`. Bump
  the server schema_version to 9 and `SyncEngine.understoodSchemaVersion` to
  9 in the same release so older clients refuse to push to a server they do
  not understand, as the highlight history migration did.
- Readiness is per Mac and never synced. After a Team Sync pull that changed
  `projects`, the active project's readiness is recomputed.

## Phases

### Phase 1: model, storage, resolver (Codex)

- `Data/ProjectLanguages.swift`: the struct, `ProjectLanguageResolver`.
- `Database.swift`: schema 43 adds `languages_json` to `projects` (ALTER
  inside the `stamped < 43` block, CREATE TABLE updated for new DBs).
- `ProjectRecord.languages: ProjectLanguages?` read in `Database+Projects`
  row mapping; `setProjectLanguages(id:languages:)` write with
  `sync_pending` marking like the other project columns.
- `SyncTable.history` "projects" gains `languages_json`;
  `understoodSchemaVersion` 9; the SQL migration file.
- Tests: `ClipBuilderTests/Data/ProjectLanguagesTests.swift` for resolver
  precedence and the transcription language choice; a `TempDatabase` round
  trip including nil; a sync-mapping test that the column is on the wire.

### Phase 2: readiness service and install job (Codex)

- `Services/Languages/LanguageReadiness.swift` with `LanguageProbe.live`.
- `AppJobKind.languageAssets` ("Language Assets") and
  `AppStore+Languages.swift`: `languageAssets: [LanguageAsset]` state,
  `refreshLanguageReadiness()` (on project select, profile change, Team Sync
  completion, app activation), `installLanguageAssets()` job that installs
  recognizers through `AssetInventory` with progress and leaves translation
  and voices to the view.
- Tests: `LanguageReadinessTests` with a stub probe (all installed → no
  missing; one downloadable → listed; translation pairs skip same-language;
  dub engine routes to the right probe).

### Phase 3: UI (Codex)

- `Views/ProjectLanguagesSheet.swift` editor; entry points on the project
  card menu and a visible button in the card footer, Sources banner, Project
  settings.
- `LanguageReadinessBanner` on Sources with Install, Languages…, and the
  translation `translationTask` trigger.
- Project card language row and badge.
- Ask AI: `ProjectsAssistant` and `SourcesAssistant` get a `languages.install`
  action and an insight when assets are missing (`AssistantSuggestion`
  kind `.insight`).

### Phase 4: routing (Codex)

- Replace the 21 `footage.language` reads on the transcription path with
  `store.transcriptionLanguage(for: video)` which resolves through the
  active project. Settings keeps the profile field as the default for new
  projects; its caption says so.
- `TranscriptionService.transcribePodcast` auto-detect samples the project's
  spoken locales before en-US/pt-BR when the project lists more than one.
- Pre-flight checks in `transcribe(video:)`, the analysis step batch and the
  wizard pipeline: a required recognizer that is `downloadable` or
  `unsupported` stops the action with `LanguageReadiness.summary` and the
  Install route.
- Tests: `AnalysisRequest` captures the resolved language (it already stores
  `language`), and a `WizardPipeline` test that a project language overrides
  the profile.

### Phase 5: verification (Claude)

- Debug build, run the Assistants, Languages and Projects suites.
- Drive live on a scratch data copy: set a project to pt-BR + en captions on
  a Mac without the pt-BR recognizer (remove it in System Settings or use a
  stub probe flag `-ClipBuilderLanguageProbeStub`), confirm the banner,
  Install, and that Transcribe refuses before install and runs after.
- Apply the server migration before the release that ships
  `understoodSchemaVersion` 9.

## Out of scope

- Installing Siri or Mac voices (not possible from an app).
- Per-video languages. A video in a language the project does not list is
  handled by auto-detect as today.
- Syncing readiness state between Macs.
