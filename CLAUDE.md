# Clip Builder

Native macOS app (SwiftUI, macOS 26 target, Xcode beta) that turns a profile's
source footage into short-form clips: analyze scenes, build timelines, render,
critique, publish to Instagram. Solo-built. About 110k lines of app code in 446
Swift files, plus 27k lines of tests. Nobody can hold it in context: search, read
slices, verify with the compiler.

## Build, test, run

- Build and launch: follow `.claude/skills/run-app`. Scheme is `MyApp`, not
  "Clip Builder". `DEVELOPER_DIR` must point at Xcode-beta. Ad-hoc signing only.
- Compile check after a change: `build-for-testing` in Debug into `build-debug`.
  That is enough. Do not run a Release build or the test suite per change.
- Tests run in exactly one place: `scripts/release.sh` calls `scripts/test.sh`
  and aborts the release if anything fails. Only run `scripts/test.sh <Suite>`
  directly when the user asks. Tests use Swift Testing (`@Test`, `#expect`).
- Release: `.claude/skills/release`. Never run it with untracked files in the
  tree; it treats them as dirty.
- Before pushing, check formatting on changed files. There is no SwiftLint or
  swift-format config; match the surrounding file.

## Rules that are not in the code

- Long AI or media work never runs inside a modal sheet. It goes through
  `AppJobs` (`ClipBuilder/App/AppJobs.swift`): start, dismiss, status-bar row
  with Stop, review sheet from the root view. See docs/Async-AI-Actions-Plan.md.
- Every feature needs a visible control on a card, inspector, or toolbar. A
  context-menu-only entry point is a bug.
- Codable settings and record structs use synthesized decoding. A new stored
  property must be Optional or decoding of existing JSON breaks.
- Toolbar and controls-row text is `lineLimit(1)` plus `fixedSize`, or
  `ViewThatFits`. A wrapping label in a split pane pushes content offscreen.
- Change detection on files uses `FileManager.attributesOfItem`, never
  `URL.resourceValues`, which caches per URL value.
- Hardware encodes are not byte-deterministic. Compare renders by timing, audio,
  and per-frame SSIM (`compareDecoded` in `MultitrackRenderTests`).
- Default actor isolation is MainActor. Anything that must run off the main
  thread is `nonisolated` or an actor; CPU work over ~50 ms never runs on a
  main-actor Task. `MainThreadWatchdog` logs stalls over 0.5 s.
- Do not touch: `scripts/release.sh`, `scripts/make_pkg.sh`,
  `build/performance-baseline*`, `PRODUCT.md`, `DESIGN.md`.

## Working agreement

- Codex implements; Claude builds, tests, and reviews. `HANDOFF.md` at the root
  is the baton between them (Done / Unverified / Next / Do not touch). Read it
  first, rewrite it before stopping, never commit it.
- Never commit or push unless asked. No AI attribution in commits or PRs.
- Plan docs go in `docs/` as `<Feature>-Plan.md` with a date and status line at
  the top. Implementation follows the plan's phases.

## Map

```
ClipBuilder/
  App/        AppStore (7.3k lines, the hub) + AppStore+<Feature> extensions,
              AppJobs (background jobs), BuilderStore (timeline editing)
  Data/       Models, Database (4.7k lines, SQLite), BrandProfile, settings,
              recipes, AI provenance
  Services/   107 files: Analyzer, MultitrackRenderer, WizardEngine (3.6k),
              AIService (provider dispatch), ReelCritic, PodcastHighlight*,
              GoogleDrive/, Instagram/, Models/ (on-device CreateML), Script/
  Views/      106 files, one per sheet or pane; GoogleDrive/, AIInfo/ subfolders
ClipBuilderTests/  mirrors the app folders; Support/ has fixtures
docs/       plans and results; scripts/  release, test, benchmarks
```

Where to look first:

| Topic | File |
| --- | --- |
| App-wide state and most actions | `App/AppStore.swift`, MARK sections listed at each `// MARK: -` |
| Background jobs, review queue | `App/AppJobs.swift`, `App/AppStore+Jobs.swift` |
| AI provider routing, task names | `Services/AIService.swift`, task catalog in `Data/AppSettings.swift` (`AICatalog`) |
| Reel generation pipeline | `Services/WizardEngine.swift`; critique in `Services/ReelCritic.swift` |
| Rendering | `Services/MultitrackRenderer.swift` |
| Scene analysis | `Services/Analyzer.swift` |
| Google Drive | `Services/GoogleDrive/GoogleDriveClient.swift`, `Views/GoogleDrive/GoogleDriveBrowserSheet.swift` |
| DB schema and queries | `Data/Database.swift` |
| On-device models, agreement reports | `Services/Models/`, `App/AppStore+ReelModels.swift` |

AI calls are one-shot: `ai.call(prompt:task:frames:)` with a task name string
(29 of them, e.g. "wizard", "critique", "distill", "curate"). Each task has its
own prompt builder and a provider chain in `AICatalog`. Responses are parsed
with `AIResponseParser.jsonObject`.

## Runtime and verification

- App data: `~/Documents/ClipBuilder/`. Launch with
  `-ClipBuilderDataFolder <path>` to point at scratch data. Tests launch the app
  into `/private/tmp`; reading `~/Documents` at launch hangs the test host.
- After an ad-hoc rebuild, "authorization denied (extended code 23)" on the DB
  is a TCC denial, not a DB fault: `tccutil reset SystemPolicyDocumentsFolder`
  for the bundle id.
- The user shares this machine and may have their own Clip Builder instance
  open. Drive UI by pid, with real CGEvent clicks in points, and verify through
  state on disk rather than screenshots alone.
- `ffmpeg` and `ffprobe` on PATH are required for media features.

## Docs that are current

- `docs/Async-AI-Actions-Plan.md`: the jobs pattern, implemented in 1.88.
- `docs/Builder-Scripting-Reference.md`: the Builder script language.
- `docs/Critic-Brief-Plan.md`: draft, not implemented.
- `docs/TESTING-PLAN.md`: the original test strategy, written before the suite
  existed; the conventions still hold, the "no tests yet" framing does not.
- `docs/Performance-*.md`: results of the 2026-09 performance work; history,
  read only when touching render or cache code.
- Other `*-Plan.md` files are implemented and kept as history.
