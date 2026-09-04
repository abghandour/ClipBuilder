# Clip Builder testing plan

Purpose: add automated tests to a macOS SwiftUI app that currently has none, so
that changes can be verified before release. This document is written for an
AI agent to execute. Facts below were verified against the repo on 2026-09-04;
re-check line numbers, they drift.

## 1. Project facts you need

- Repo root: `/Users/abghandour/repos/ClipBuilder`. Project: `Clip Builder.xcodeproj`
  (path has a space, keep quotes). Sources live under `ClipBuilder/` in a
  `PBXFileSystemSynchronizedRootGroup` (objectVersion 90): files on disk are
  picked up automatically, no pbxproj edits per file.
- One target. Scheme is `MyApp` (shared, `xcshareddata/xcschemes/MyApp.xcscheme`).
  Product name is `Clip Builder`, bundle id `com.mokotti-solutions.clipbuilder`.
- Build settings that matter: `ENABLE_TESTABILITY = YES`,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`,
  `MACOSX_DEPLOYMENT_TARGET = 26.0`, Swift language version 5 mode.
- Build command (from `.claude/skills/run-app/SKILL.md`):

  ```bash
  DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project "Clip Builder.xcodeproj" -scheme MyApp -configuration Debug \
      -derivedDataPath build -destination 'platform=macOS' \
      CODE_SIGN_IDENTITY=- build 2>&1 | xcbeautify
  ```

  `DEVELOPER_DIR` is required (xcode-select points at Command Line Tools).
  `xcbeautify` may not be installed; drop the pipe if so. Replace `build` with
  `test` once the test target exists.
- No SwiftLint config, no SPM dependencies, no `.github/` directory, no CI.
- External dependencies of the app: `ffmpeg`/`ffprobe` at `/opt/homebrew/bin`
  (present on this machine), AI CLIs (`claude`, `gemini`, `codex`) launched as
  subprocesses, network (Instagram Graph API, update check, fight research),
  SQLite via `sqlite3` C API, UserDefaults, and app data under
  `~/Documents/ClipBuilder/`.
- Existing seams, usable with no code changes:
  - Data folder override: `UserDefaults` key `ClipBuilderDataFolder`
    (`ClipBuilder/Data/AppSettings.swift`, `SettingsStore.dataFolderDefaultsKey`).
    Everything under `SettingsStore` derives paths from it.
  - `Database(path: URL)` (`ClipBuilder/Data/Database.swift`) opens any file path.
  - AI provider binary is configurable: `AIConfig.providers[key].bin` is looked up
    through `ProcessRunner.locate`, which accepts absolute paths. A test can point
    a provider at a shell script.
  - `ProcessRunner.run(executable:arguments:stdin:timeout:environment:)` is the
    single subprocess entry point.
- Architecture: `AppStore` (`ClipBuilder/App/AppStore.swift`, 4200 lines,
  `@Observable @MainActor`, ~180 methods) owns state and jobs; its `init()`
  loads settings, profiles, opens the DB, and starts a `FolderWatcher`.
  `BuilderTimelineModel` (`ClipBuilder/App/BuilderStore.swift`) is the Builder's
  main-actor model with undo. Services are actors: `WizardEngine`, `Analyzer`,
  `AIService`, `RenderEngine`, `MultitrackRenderer`, `InstagramService`,
  `FightResearchService`, `ThumbnailService`, `CenterStageService`. Model
  types in `ClipBuilder/Data/` are `nonisolated` structs, mostly Codable.
  There are zero protocols in the codebase.

## 2. Known regression classes (drive test priority)

From the commit history (`git log`, commit 2091be4 lists ~25 bugs). Each of
these must get a regression test in the phase noted.

| Bug that shipped | Where | Phase |
|---|---|---|
| Slow-motion clips changed length across save/load | `TimelineClip` Codable | 1 |
| Trim clamp and preview scrubbing ignored speed | `BuilderTimelineModel.trimClip`, `sourceTime` | 2 |
| Negative track index crashed on drag | `BuilderTimelineModel.trackIndex(fromTrack:verticalDelta:)` | 2 |
| Clear Timeline undone by pending autosave | `BuilderTimelineModel.clear` / undo | 2 |
| Faded text overlays starting after t=0 invisible in renders | `MultitrackRenderer.addOverlays` | 3 |
| Fresh DB failed: indexes created before tables | `Database.schema` | 2 |
| `SQLValue.intValue` trapped on non-finite REAL | `ClipBuilder/Data/SQLite.swift` | 1 |
| Profile switch leaked previous profile's ids | `AppStore.profileGeneration` | 4 |
| Duplicate shortcodes double-counted on import | `PeaceGrapplerImporter` | 1 |
| Five JSON stores wrote non-atomically; case-only rename failed on APFS | JSON stores in `Data/` | 2 |
| Screen-crop masks on uncropped wide clips failed alphamerge | `MultitrackRenderer.compositeLayeredSegment` | 3 |

## 3. Phase 1: test target and pure-logic tests

### 3.1 Create the test target

1. Create folder `ClipBuilderTests/` at repo root.
2. Add a Unit Testing Bundle target named `ClipBuilderTests` to
   `Clip Builder.xcodeproj`, host application `MyApp` (the app target),
   using the Swift Testing framework (`import Testing`). Do this with Xcode
   (`File > New > Target`) or by editing the pbxproj: add a
   `PBXNativeTarget` of type `com.apple.product-type.bundle.unit-test`, a
   `PBXFileSystemSynchronizedRootGroup` pointing at `ClipBuilderTests`,
   `TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Clip Builder.app/Contents/MacOS/Clip Builder"`,
   `BUNDLE_LOADER = "$(TEST_HOST)"`, and a target dependency on the app.
3. Set on the test target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
   `SWIFT_APPROACHABLE_CONCURRENCY = YES` to match the app, otherwise calls into
   main-actor classes will not compile cleanly. Swift Testing runs tests off
   the main actor by default; mark suites that touch `BuilderTimelineModel`
   or `AppStore` with `@MainActor`.
4. Add the test target to the `MyApp` scheme's Test action (edit
   `MyApp.xcscheme`, `Testables`).
5. Verify with an empty `@Test` that:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
   xcodebuild -project "Clip Builder.xcodeproj" -scheme MyApp \
       -destination 'platform=macOS' -derivedDataPath build \
       CODE_SIGN_IDENTITY=- test
   ```

   passes. Every test file starts with `@testable import Clip_Builder`
   (module name derives from the product name; confirm with the build log
   if the import fails).

### 3.2 Support layer (`ClipBuilderTests/Support/`)

- `TempDirectory.swift`: creates a unique directory under
  `FileManager.default.temporaryDirectory`, removes it in `deinit`.
- `TempDatabase.swift`: `func makeDatabase() throws -> Database` backed by a
  temp file. Also a helper that seeds one video and N scenes through
  `registerVideo` and `saveAnalysis`.
- `DataFolderOverride.swift`: sets `ClipBuilderDataFolder` to a temp path in
  `UserDefaults.standard`, restores the previous value after. Tests that touch
  `SettingsStore`, `ProfileStore`, or any JSON store must use it so the real
  `~/Documents/ClipBuilder` is never read or written.
- `Fixtures.swift`: builders for `TimelineDocument`, `TimelineClip`,
  `SceneRecord`, `VideoRecord`, `WizardPlan`, `BrandProfile` with sensible
  defaults and keyword overrides.
- `Fixtures/` folder (bundle resources): saved HTML pages for the Instagram
  parsers, canned AI JSON replies, a small `.db` from an older build
  (phase 2).

### 3.3 Pure-logic tests, one file per source file

Write these in priority order. Each bullet is a `@Suite`.

1. `Data/TimelineDocumentTests.swift`
   - Encode then decode `TimelineDocument` with clips at speeds 0.5, 1, 2 and
     assert `duration`, source range, and timeline span survive (regression).
   - `TimelineClip`, `SoundItem`, `TextOverlayItem`, `ImageOverlayItem`,
     `TrackSettings`, `CropBlockItem` custom `encode(to:)` round trips.
   - `normalizeCropBlocks(winner:minimumEnd:)` on overlapping blocks.
   - `migrateLegacyScreenCrops()` from a hand-written legacy JSON document.
   - `expandingOverlayBlocks()`, `cropBlock(at:)`, `hasArea(track:at:)`,
     `isOrphaned(_:)`.
   - `CropLayoutRef.resolve(reference:)` accepts and rejects references.
2. `Services/MultitrackRendererPlanningTests.swift` (static, no ffmpeg)
   - `resolveClips(document:scenes:...)`, `applyCropBlocks`,
     `buildLayeredSegments`: sequential tracks, overlapping tracks, gaps,
     a clip whose scene is missing.
3. `Services/WizardEngineTests.swift`
   - `WizardEngine.timelineDocument(from:...)` and `legacyTimelineDocument(fromFlat:)`.
   - `WizardTextStyle.sanitizedAccent`, `WizardPlan.slug`.
   - Change `private func validatePlan` to `func validatePlan` (internal) and
     feed malformed plans: missing keys, clips outside scene range, negative
     durations, unknown transitions. Assert rejection or clamping.
   - `WizardOptions.screenCropLayoutsFromDefaults` /
     `allowedTransitionsFromDefaults` with the defaults override.
4. `Services/AIServiceTests.swift`
   - `AIResponseParser.jsonObject(from:)` with fenced JSON, leading prose,
     trailing text, invalid input. `AIProgressLine.from`.
   - `AIService.dispatchCandidates` and `resolveProviderModel` ordering for
     each task with and without overrides (actor, but no IO).
5. `Services/AnalyzerStaticTests.swift`
   - `frameTimestamps(duration:interval:)` and the start/end overload.
   - `sanitizedFilenameSuggestion(_:currentFilename:)`,
     `isSpellingFix(of:candidate:)` (must never accept a different name),
     `primaryPeopleBoxes`, `breakdownPrompt`.
6. `Services/Instagram/ReportBuilderTests.swift`
   - `InstagramReportBuilder.build`, `accountInsights`, `score`, `isEarly`,
     `isEmojiOnly`, `rankings`, `activity` with fixed `now`.
   - `ReportHTML` helpers, `EngagementReportParser.parse`,
     `InsightsPageParser.parse` against fixture HTML in the bundle.
   - Importer dedupe: extract the shortcode dedupe from
     `PeaceGrapplerImporter.run` into a static function if needed, then test
     duplicates collapse to one row.
7. `Services/SmallStaticsTests.swift`
   - `TextOverlayRenderer.parseMarkup`, `plainText`, `wordCount`, `parseColor`.
   - `RenderEngine.consumedOverlap(_:xfadeDuration:)` for each transition name.
   - `FightScoring.points(for:)`, `GeneratedVideoRecord.clipReasons(fromPlanClipsJSON:)`.
   - `BuilderTimelineModel.snap`.
   - `SQLValue.intValue` / `doubleValue` for NaN, infinity, huge reals, text.
   - `AICatalog.modelDisplayName`, `AICatalog.provider`.
8. `Data/SettingsCodableTests.swift`
   - `AppSettings`, `AIConfig`, `TransitionSettings`, `InstagramSettings`
     decode from an older JSON shape with missing keys (defaults apply) and
     round trip.

## 4. Phase 2: database and Builder state

1. `Data/DatabaseTests.swift`
   - Fresh file: schema creates, `PRAGMA user_version` equals
     `Database.schemaVersion` after open, second open skips migration.
   - Commit `ClipBuilderTests/Fixtures/legacy-v0.db` created by checking out
     tag for release 1.40 or earlier and running the app against a scratch
     data folder, then copy `data/profiles_db/Default.db`. Test that opening
     it migrates and every expected column exists (`columnNames(of:)`).
   - CRUD: `registerVideo`, `saveAnalysis`, `fetchScenes` with tags and
     grades, `setSceneFavorite`, `setSceneCurated` with provenance,
     `addGrade` averages, `deleteAnalysisRun` cascades scenes and tags,
     `mergePeople`, `renameVideo`, `videoNotes`, `personMarkers`,
     `fetchOutcomes` keeps latest per video.
   - WAL fallback: open a DB in a read-only directory and assert it falls back
     to DELETE journal rather than failing (see memory note on v1.12).
2. `App/BuilderTimelineModelTests.swift` (`@MainActor`)
   - `addScene`, `placeClip`, `trimClip` at speed 2 (regression), `setClipSourceRange`,
     `duplicateClip`, `removeClip`, `addCropBlock`, `setCropLayout`,
     `resizeCropBlock`, `setTrackSequential`, `resolveLayout`.
   - Undo/redo after each operation restores the previous document exactly
     (`TimelineDocument: Equatable`).
   - `trackIndex(fromTrack:verticalDelta:)` never returns negative (regression).
   - `clear()` then a simulated autosave does not resurrect content (regression).
   - `load(profileName:)` and `loadDocument` reset undo history.
   - `updateChangedScenes` rehydrates clips whose scene range changed.
3. `Data/JSONStoresTests.swift` with the data-folder override
   - `ProfileStore`, `SettingsStore`, `OverlayTemplateStore`, `ScreenCropStore`,
     `WizardPreferences`: save, load, atomic write (no partial file on
     simulated failure), case-only rename succeeds, `ensureDefaultProfile`.

## 5. Phase 3: integration tests with real ffmpeg and a fake AI

Tag with `.tags(.integration)` and skip when
`ProcessRunner.locate("ffmpeg") == nil`.

1. `Support/FixtureVideo.swift`: generate clips on demand into the temp dir:

   ```bash
   ffmpeg -y -f lavfi -i testsrc=size=1280x720:rate=30 -f lavfi -i sine=frequency=440 \
          -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac out.mp4
   ```

   Also a wide 1920x1080 variant and a silent variant. Never commit video files.
2. `Integration/RenderEngineTests.swift`: `extractClip`, `normalizeClip`,
   `extractSubclip`, `concatenate` with `nil` and each transition name,
   `overlayMusic`, `detectContentBox` on a letterboxed fixture. Assert with
   `FFmpeg.duration(of:)`, `FFmpeg.dimensions(of:)`, `FFmpeg.hasAudioStream`.
3. `Integration/MultitrackRenderTests.swift`: render a document with two tracks,
   a crop block, a text overlay that starts at 1.0s with a fade (regression),
   a slow-motion clip, and background music. Assert output duration within
   0.1s and that the file plays (ffprobe succeeds).
4. `Integration/FakeAIProviderTests.swift`: `ClipBuilderTests/Fixtures/fake-claude.sh`
   reads stdin and prints a canned JSON reply chosen by a substring of the
   prompt (plan, caption, analysis). Build an `AIConfig` whose provider
   `bin` is that script's absolute path. Run `WizardEngine.plan` and one
   `Analyzer.analyzeVisual` against a temp database and fixture video and
   assert rows land in the DB. This exercises prompt building, response
   parsing, and persistence together.

## 6. Phase 4: AppStore, UI smoke, gating

1. Add an injectable initializer to `AppStore`:
   `init(settings: AppSettings, profiles: [BrandProfile], active: BrandProfile, ai: AIService, ...)`
   and make the existing `init()` call it. Keep `FolderWatcher` optional.
   Then test in `App/AppStoreTests.swift` (`@MainActor`): `presentError`
   queue order and cancellation drop, `switchProfile` bumps `profileGeneration`
   and clears lists, a completion carrying an old generation is ignored
   (regression), `scenes` didSet rebuilds `SceneIndex` and bumps
   `scenesVersion`, comparison batches queue FIFO.
2. UI smoke: add a UI Testing Bundle `ClipBuilderUITests` with one test that
   launches with `-ClipBuilderDataFolder <tempdir>` in `launchArguments`,
   clicks each sidebar item (⌘1 through ⌘9), opens the Builder, and asserts no
   crash. Purpose: catch AppKit layout-guard crashes seen on macOS 27 betas.
   Do not expand UI tests beyond smoke coverage.
3. Gating:
   - In `scripts/release.sh`, run the `xcodebuild ... test` command (unit
     target only, `-only-testing:ClipBuilderTests`) before the package step
     and abort on failure.
   - Add `scripts/test.sh` wrapping the command with `DEVELOPER_DIR`, and a
     `.git/hooks/pre-push` sample in `scripts/hooks/` that calls it.
   - Later: GitHub Actions on a `macos-26` runner running `scripts/test.sh`
     without the integration tag. Not first, because the local toolchain is
     Xcode beta on macOS 27.

## 7. Conventions

- Swift Testing (`@Test`, `#expect`, `#require`), not XCTest, except the UI
  bundle which must use XCTest.
- One test file per source file, mirrored path under `ClipBuilderTests/`.
- Tests never read or write `~/Documents/ClipBuilder`, `UserDefaults` keys
  other than through the override helper, or the network.
- Prefer making a `private` function `internal` over restructuring code.
  Do not introduce protocols just for mocking; the existing seams
  (configurable binary paths, injected actors, path parameters) are enough.
- Every regression from section 2 gets a test whose name includes
  `regression`.
- Run the full unit suite after each phase and record the command output in
  the final report. Do not commit or push unless asked.
