# Page Assistant: Ask AI on every screen, with context-aware suggestions

Date: November 1, 2026. Status: implemented November 1, 2026 (all phases), uncommitted; Codex-reviewed three times, all findings applied.
files are named, so Codex implements phase by phase; Claude builds, tests,
drives it live on scratch data and reviews.

## What exists

The sparkles toolbar button is `AskAIToolbar` in `Views/Theme.swift`, applied
with `.askAI(_ assistant: (any PageAssistant)?)` next to `.screenTitle`. It
opens `Views/AskAIPopover.swift`: a text field, three example chips, Send, and
the last outcome line. `Services/Assistants/PageAssistant.swift` is the
protocol (`page`, `examples`, `handle(_:store:) -> AskAIOutcome`). Three pages
have an assistant: Builder (`BuilderAssistant`, keyword routing to image
generation or the Builder Wizard), AI Wizard (`WizardAssistant`, hands the text
to the visible Express or Full form) and Instagram Reports (`ReportAssistant`,
an AI Report job). Every other page shows no button. Nothing today reads the
page's settings, and nothing suggests; the user has to know what to type.

## Goal

1. The button is on every page of the app, including the Projects home, AI
   Lessons, Text Looks and the Settings-less resource browsers.
2. Opening it shows **suggestions** computed from the page *and its current
   settings and selection*: what the AI would do next here, each with a
   one-line reason and a Run button. Settings-level suggestions change
   settings ("Turn on captions: this source has speech"); action-level ones
   start the work the page already offers ("Analyze 3 sources that have no
   scenes").
3. Free text still works everywhere and is understood against the same
   context: "make it 30 seconds" on Express sets Length, "only the fight
   scenes" on Scenes applies the filter, "publish the newest one" on Exports
   opens the publish sheet.
4. The popover shows what the assistant sees ("Express · Highlights · Auto ·
   captions off · 1 source · 2 earlier highlights"), so suggestions are
   explainable and the user can tell when a setting is stale.

Non-goals: a chat transcript, multi-turn memory, or the assistant running
work the page cannot start by its own visible controls. Every action it runs
must be reachable from a card, inspector or toolbar already (CLAUDE.md rule).

## Design

### Context, suggestions, actions (pure, tested)

New file `Services/Assistants/AssistantContext.swift`:

```swift
nonisolated struct AssistantContext: Equatable, Sendable {
    var page: String                       // "AI Wizard"
    var subpage: String?                   // "Express", "Reports", "Captions"
    var facts: [AssistantFact]             // what the page knows, in order
    var settings: [AssistantFact]          // current page settings, label + value
    var selection: [String]                // names/ids of selected items, max 20
    var fingerprint: String                // stable hash of the above for caching
    var summaryLine: String                // "Express · Highlights · Auto · captions off"
}
nonisolated struct AssistantFact: Equatable, Sendable { var key: String; var label: String; var value: String }

nonisolated struct AssistantSuggestion: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case setting, action, insight }
    var id: String                         // "express.captions.on", "sources.analyze.missing"
    var kind: Kind
    var title: String                      // "Turn on captions"
    var reason: String                     // "This source has speech and captions are off"
    var actionID: String?                  // nil for an insight with nothing to run
    var provenance: AIProvenance?          // nil when rule-based
}

nonisolated struct AssistantAction: Identifiable, Sendable {
    var id: String
    var title: String
    var systemImage: String                // reuse the page's own symbol, never a new one
    var isAvailable: @MainActor (AppStore) -> Bool
    var run: @MainActor (AppStore) -> AskAIOutcome
}
```

`PageAssistant` grows, with defaults so the three existing assistants keep
compiling:

```swift
nonisolated protocol PageAssistant: Sendable {
    var page: String { get }
    var examples: [String] { get }
    @MainActor func context(store: AppStore) -> AssistantContext
    @MainActor func actions(store: AppStore) -> [AssistantAction]
    /// Rule-based, instant. Pure given the context so it is testable.
    func suggestions(for context: AssistantContext) -> [AssistantSuggestion]
    @MainActor func handle(_ text: String, store: AppStore) -> AskAIOutcome
}
```

Rule: `suggestions(for:)` is `nonisolated`, takes only the context, and has a
test per page under `ClipBuilderTests/Services/Assistants/`. `context(store:)`
reads the store and the page's persisted view settings; it never reads the
database (counts the page already holds are enough).

### Page settings are the context

Settings a page keeps in `@State` are invisible to the store. Each page that
has such state publishes a snapshot through a new environment-free hook:
`.askAI(assistant, pageState: AssistantPageState)` where
`AssistantPageState` is a small `Equatable` struct of the page's filter and
sort state (Scenes: favoritesOnly, tagFilter, showHidden, searchText,
sortByScore, selectedRunIDs count, selected scene ids; Exports: selectedFolder,
sort; Sources: selection, sortOrder; Text Looks: tab). The modifier stores it
on `AssistantModel` (below) keyed by page, and `context(store:)` reads it from
there. Pages whose state already lives on the store (Express settings via
`MiniWizardSettings`, Full wizard `WizardOptions`, Builder document) need no
snapshot.

### The model and the popover

New `App/AppStore+Assistant.swift` with an `@Observable final class
AssistantModel` on the store (`store.assistant`):

- `pageState: [String: AssistantPageState]`, `lastOutcome: [String: AskAIOutcome]`.
- `suggestions(for assistant:) -> [AssistantSuggestion]`: rule-based list from
  the current context, then (Phase 3) the AI-ranked list when its fingerprint
  matches, merged by id, max 5.
- `dismissed: Set<String>` persisted in UserDefaults
  (`assistant.dismissed.<profile>`); a dismissed suggestion id hides until its
  reason changes (the id carries the reason's key, see Phase 2 ids).
- `refresh(assistant:)`: cancels the previous AI fetch, starts one for the new
  fingerprint (Phase 3). Short, cancellable Task owned by the model; not an
  AppJob, because a suggestion fetch must not add a status-bar row. Hard
  timeout 12 s, falls back to rules.

`Views/AskAIPopover.swift` becomes three sections, in this order:

1. **Context line** (caption, secondary): `context.summaryLine`, with a
   tooltip listing every fact and setting. This is the "what the AI sees" row.
2. **Suggestions**: up to 5 rows, each `title`, `reason` (caption), a Run
   button, and a small `×` to dismiss. A `setting` kind shows a switch-like
   "Apply" label; an `insight` shows no button. A provenance badge
   (`ProvenanceBadge`) when AI-ranked. Empty state: "Nothing to suggest here".
   While an AI refresh is in flight the rule-based rows show at once and a
   `ProgressView` sits in the section header; rows reorder in place when the
   AI list lands, never flicker to empty.
3. **Ask**: the existing text field, examples, Send.

Width 420. The popover keeps `lineLimit(1)` on titles and wraps reasons.
Keyboard: ⌘⇧A opens Ask AI on the current page (new command in
`ClipBuilderApp` commands, routed through `store.assistant.openRequest`).

### Free text against the context (Phase 3)

Each assistant's `handle` tries its own rules first (as today). When nothing
matches, the model calls the new `AITask.assist` once with the context, the
action catalogue (`id`, `title`) and the settings the page allows the
assistant to change (keys and allowed values), and expects
`{"action": id | null, "settings": {key: value}, "reply": text}`. The model
applies settings through the page's `apply(settings:)` closure (whitelisted
keys only), runs the action, and reports `.handled(reply)`; an unknown action
or key becomes `.unavailable`. Parsed with `AIResponseParser.jsonObject`.

`AITask.assist` ("Page Assistant"): default provider claude, chain claude →
antigravity → gemini like `.report`; no frames; `AICatalog` label and
recommended chain keyed by `"assist"`. Settings and provenance keys follow.

## Phases

### Phase 1: protocol, model, popover (Codex)

Files: `Services/Assistants/AssistantContext.swift` (new),
`Services/Assistants/PageAssistant.swift` (extend with defaults),
`App/AppStore+Assistant.swift` (new, `AssistantModel`, `store.assistant`),
`Views/AskAIPopover.swift` (sections), `Views/Theme.swift` (`AskAIToolbar`
passes page state, reads `store.assistant`), `ClipBuilderApp.swift` (⌘⇧A).

Convert the three existing assistants:

- `WizardAssistant.context`: mode; Express: source name, footage kind,
  length, every `MiniWizardSettings` field that is on or non-default
  (captions, name tags, safe area, watermark, overlay, intro/outro, framing,
  transition), kept count of the active run, number of earlier highlights for
  this video (`store.highlightHistories`), instructions excerpt. Full: chosen
  sources, scenes count, recipe/target duration, output mode, kept takes,
  `WizardOptions` on/non-default fields. Suggestions (rules):
  `express.captions.on` when the source has a transcript and captions are
  off; `express.length.shorter` when Length is Auto and the source is over
  20 min; `express.safearea.on` when a platform export is set and safe area
  off; `wizard.sources.none`, `wizard.analyze.first` (insight) when no
  scenes; `wizard.history.compare` when two or more highlights exist and none
  is a regenerate (action opens History). Actions: Generate, Open in Editor,
  Regenerate with note, toggle each setting above.
- `BuilderAssistant.context`: timeline name, duration, clip count, tracks,
  caption position/style, music, brand layers, review flags count, cleanup
  proposals count, speech polish. Suggestions: `builder.flags.review` when
  review flags exist, `builder.cleanup.apply` when cleanup proposals wait,
  `builder.polish.on` when a speech track exists and polish is off,
  `builder.captions.on` when a transcript exists and no caption track.
  Actions map to the existing inspector buttons.
- `ReportAssistant.context`: account, period, data availability.
  Suggestions: the three examples become suggestion rows with reasons from
  the report (e.g. "Reels out-reached feed 3:1 this period").

Tests: `AssistantContextTests` (fingerprint stable, summary line order),
`WizardAssistantTests` (new suggestion cases), `BuilderAssistantTests`,
`ReportAssistantTests`.

### Phase 2: every page (Codex, one page per commit-sized chunk)

Each gets `Services/Assistants/<Page>Assistant.swift`, `.askAI(...)` next to
its `.screenTitle`, and a test. Suggestion ids are `<page>.<topic>.<reason>`
so a dismissed id reappears when the reason changes.

| Page (view) | Context facts and settings | Suggestions (rule) | Actions (existing entry points) |
| --- | --- | --- | --- |
| Sources (`AnalyzeView`) | source count, analyzed / transcribed / speakers named / fight-scored counts, selection, sort | `sources.analyze.missing` (N sources lack scenes), `sources.transcribe.missing`, `sources.speakers.unnamed`, `sources.duplicates.scan` when 2+ sources share duration ±1 s, `sources.names.messy` when titles look like camera files | Analyze missing steps, Name speakers, Transcribe, Fight research, Fight story, Soundbites, Duplicates, Suggest file names, Open Wizard with selection |
| Scenes (`ScenesView`) | scene count, favorites, hidden, filters (tag, run, search, score sort), selection | `scenes.favorites.none` when none favorited and 30+ scenes (AI Favorites), `scenes.filter.active` insight when a filter hides most scenes, `scenes.search` example | AI Favorites, Scene search with the typed text, Clear filters, Sort by score, Generate from selection |
| Timelines (`TimelinesView`) | timeline count, newest, unrendered count | `timelines.render.pending`, `timelines.open.newest` | Open, Render, New from Wizard |
| Exports (`LibraryView`) | video count, folder, selection, videos without cover / critique / hook group / publish | `exports.cover.missing`, `exports.critique.missing`, `exports.hooks.try` when a video has none, `exports.flags.pending` when review flags are unresolved, `exports.publish.ready` | Cover frames, Critique, Hook variants, Review flags, Publish, Open in Builder |
| People (`PeopleView`) | people count, unnamed, unresearched, hidden | `people.research.missing`, `people.unnamed` | Research, Name, Merge |
| Instagram Posts (`InstagramView` posts tab) | account, drafts, scheduled, last publish | `instagram.text.missing` for a draft without text, `instagram.publish.due` | Write post text, Publish, Analyze reel |
| Instagram Reports | (Phase 1) | | |
| Screen Layouts, Effects, Looks, Text Looks, Bumpers, Images, Music | item counts, active tab, selection | `images.tags.missing` (Tag images with AI), `looks.import` when a reference image is selected, `text.styles.none` | Tag with AI, Import Text Looks, Generate Image, Analyze subjects |
| Projects home (`ProjectsHomeView`) | project count, active, archived, sources without a project | `projects.gap.report` monthly, `projects.starter` when the profile has no taste set | Content gaps report, Starting Style, New project |
| AI Lessons (`LearnedPreferencesView`) | lessons count, pending reviews, teaching queue size | `lessons.distill` when 5+ reviews are undistilled, `lessons.publish` when the team has none | Distill, Publish, Evaluate model |

Rule: the assistant never duplicates a page's logic for counts. If a count is
not already on the store or in the page's snapshot, the page adds it to its
`AssistantPageState`, not the assistant.

Tests per page: `<Page>AssistantTests` asserting each rule fires from a
fixture context and stays quiet otherwise.

### Phase 3: AI-ranked suggestions and free-text understanding (Codex)

- `AITask.assist` in `Services/AITask.swift` with the prompt builder
  `PageAssistantPrompt.build(context:actions:settings:question:)` in
  `Services/Assistants/PageAssistantPrompt.swift` (pure, tested for the
  exact sections and for the action catalogue being the only ids offered).
  Two modes in one task: `question == nil` asks for up to 5 ranked
  suggestions among the rule list plus any the model wants to add from the
  catalogue; `question != nil` asks for one action and settings patch.
- `AssistantModel.refresh` runs the ranking with a 12 s timeout, caches by
  fingerprint for the session, and merges by id: the model may reorder and
  rephrase reasons but cannot invent action ids. Provenance recorded on the
  suggestion and shown with `ProvenanceBadge`.
- `AICatalog` entries, Settings → AI routing row, provenance key `"assist"`.
- Per-page `apply(settings:)` whitelists: Express (`length`, `captions`,
  `nameTags`, `safeAreaOnly`, `watermark`, `transition`, `aiInstructions`),
  Full (`targetDurationSeconds`, `addCaptions`, `includeHeadline`,
  `formatPreset`, `aiInstructions`), Scenes (`favoritesOnly`, `tagFilter`,
  `searchText`, `sortByScore`), Exports (`selectedFolder`). Everything else
  is action-only.
- Tests: `PageAssistantPromptTests`, `AssistantModelTests` (merge by id,
  stale fingerprint discarded, timeout falls back to rules, unknown action
  refused).

### Phase 4: polish (Codex)

- Dismiss persistence, "Show dismissed" footer link in the popover.
- Getting Started guide: one section "Ask AI on every page" with the context
  line explained; screenshots captured by hand per the release skill.
- `UITiming.responseReady(screen: "Ask AI", ...)` on popover open so the
  page-switch benchmark tracks it.

## Rules carried from CLAUDE.md

- Long work started from a suggestion goes through `AppJobs` exactly as the
  page's own button does; the popover closes and the status bar shows the
  job. The suggestion fetch itself is the only AI call that is not a job.
- Every `AssistantAction` reuses the page's existing symbol; no new icons.
- New Codable fields (none planned) would be Optional.
- `suggestions(for:)` and the prompt builder are `nonisolated` pure code
  under Services with tests beside them.
- Popover text: titles `lineLimit(1)`; reasons may wrap inside the fixed
  width; nothing in the popover is in a split pane.

## Verification

- Unit: the per-page rule tests and the model tests above.
- Live (Claude, scratch data copy via `-ClipBuilderDataFolder`): open each
  page, confirm the button, the context line matches the visible settings
  after changing one (e.g. toggle Express captions, reopen, see "captions
  on"), run one suggestion per page and confirm the same job or sheet the
  page's own control starts, and check ⌘⇧A.
- Codex read-only review after each phase with the diff only.
