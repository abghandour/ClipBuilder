# AI Wizard UI Plan

Date: September 29, 2026. Status: implemented September 29, 2026; awaiting Claude build, tests and UI review. Sources: independent critiques
by Claude and Codex of `ClipBuilder/Views/WizardView.swift`, reconciled into the
items both agreed on. Implementation: Codex; build, tests and review: Claude (per
the September 23 working rule).

## Problem

The Wizard form asks for the idea first ("What should we make?"), but the recipe
picker under it silently decides everything else: which sources row appears,
whether length is a stepper or a picker, which model rows show. The footage that
the reel will be cut from sits in an untitled section in the middle of the form,
summarized as one line ("All analyzed scenes") behind a chevron. The user's
question, "which is more important, the source videos or the idea?", has the
answer: neither is today. The recipe is the real root of the form and both
footage and idea hang off it invisibly.

Two facts found while reading the code sharpen the problem:

1. **The brief is ignored by the Podcast highlights recipe.** `AppStore.runWizard`
   (`AppStore+Wizard.swift:413`) calls `WizardEngine.findPodcastHighlights` without
   `requestText`, and `PodcastHighlightFinder.find` has no brief parameter. Text
   typed into the box, such as "never end a scene with a question", never reaches
   the model on that recipe. Only the generate-request job path parses the text,
   and only for a count, a recording name, framing and B-roll flags.
2. **Displayed settings can differ from the submitted run.** Pacing and render
   controls bind to `activeProfile` defaults, but `WizardView.runWizard` prefers
   pasted overrides when `pastedSnapshot` is set, and `computeSourcePool` applies
   pasted source restrictions that `sourceSummary` does not describe.

## Goal

One form whose top card shows the footage that will be used, whose text box is
honest about what it influences, and which can be entered either from footage or
from an idea, converging on the same plan. Nothing about the engine's planning
changes except wiring the brief where it is currently dropped.

Non-goals: new recipes, changes to `WizardSourcePickerSheet`'s batch model beyond
grouping, a separate "idea" wizard, or any change to the review sheets.

## Agreed items

Numbers in parentheses refer to the original lists (C = Claude, X = Codex).

### 1. Wire the brief into Podcast highlights (X2)

Do this first; otherwise every later item makes a text box more prominent that
one recipe ignores.

- `AppStore.runWizard` passes `options.aiInstructions` as `requestText` to
  `findPodcastHighlights`, matching what the request-job path already does.
- `PodcastHighlightFinder.find` gains an `instructions: String` parameter appended
  to its prompt as a "USER RULES" block. The exchange-scoring prompt in
  `PodcastAnalysisService` is unchanged.
- Until the finder is topic-aware, the form's caption under the text box for this
  recipe reads "Rules for choosing highlights", not "Describe the outcome".
- Test: `PodcastHighlightFinderTests` asserts the rules block appears in the prompt
  when instructions are non-empty and is absent when empty.

Files: `AppStore+Wizard.swift` (`runWizard`), `WizardEngine.swift`
(`findPodcastHighlights`), `PodcastHighlightFinder.swift` (`find`),
`WizardView.swift` (caption text).

### 2. Sources card at the top, with evidence and readiness (C2, C6, X3, X5)

Replace the untitled section that holds the `LabeledContent("Sources")` row and
the `Picker("Podcast")` with a titled `Section("Sources")` placed **above** the
recipe. It shows:

- for scene recipes: usable scene count and video count from `sourcePool`, the
  people filter as `PersonFaceAvatar` chips, up to six scene thumbnails, and an
  Edit button that opens the existing `WizardSourcePickerSheet`;
- for Podcast highlights: the recording picker, its duration, and whether a
  transcript and exchanges exist;
- a readiness line in the same orange style the music and caption warnings use:
  "Choose at least one Analyze batch", "No favorites in this selection",
  "Transcript required", "No exchanges analyzed yet", each with the recovery action
  beside it (Open Sources, Analyze). The generation bar's current warnings move here.
- scope label "This project". `WizardSourcePickerSheet.sourceExplanation` currently
  says "profile"; correct it.

Readiness must derive from the same eligibility the engine applies.
`WizardFormPlan` gains a `readiness(pool:videos:transcripts:)` function returning
`[Readiness]` (`ok`, `warning(message, action)`) and `canGenerate` becomes "no
readiness item is blocking". Counting `sourcePool` alone is not enough: the engine
additionally requires a transcript for podcast highlights
(`WizardEngine.findPodcastHighlights`).

In the picker sheet, group Analyze batches under their video with the batch row
disclosed as an advanced detail; the video is the object the user recognizes.

Files: `WizardView.swift` (`configurationForm`, `canGenerate`, `sourceSummary`,
`generationBar`), `WizardFormPlan.swift`, `WizardSourcePickerSheet.swift`
(`body`, `batchRow`, `sourceExplanation`).

### 3. Two entry paths that converge on one plan (C1, X1)

Not two wizards. A segmented control at the top of the form, shown only when the
Wizard opens without a handoff:

- **From footage.** The Sources card is expanded and focused; the recipe picker
  lists recipes whose `Capabilities.sources` matches the chosen footage first, the
  rest under a divider. The brief follows the recipe.
- **From an idea.** The brief is first, with placeholder text per recipe (see
  item 5). On Generate, the existing generate-request job
  (`startGenerateRequest`) parses the text into a `WizardPromptHandoff`; the
  resulting `applyPromptHandoff` populates the Sources card so the user sees the
  matched footage **before** the plan runs. The current behavior, which applies
  the handoff and continues straight into planning, becomes a second confirm.

Handoffs from Scenes, People and Timelines (`pendingWizardPrompt`,
`pendingWizardTemplate`) open directly in From footage with the selection applied.
The mode is remembered in `@AppStorage("wizard.entryMode")`.

Files: `WizardView.swift` (`configurationForm`, `applyPromptHandoff`,
`startGeneration`), `AppStore+Wizard.swift` (`startGenerateRequest`,
`generateSampleVideo`).

### 4. Outcome section: one reel versus highlights to review (X4, C4)

Podcast highlights is a different workflow wearing a recipe's clothes: it produces
several reels, reviews every candidate, and removes captions, music and branding.
Lead the section after Sources with a two-way picker, **Create one reel** or
**Find highlights to review**, then the recipe picker filtered to that path.
`ReelRecipe.menuSections` gains a `workflow` tag on each recipe so the filter is
data, not a special case.

The recipe's `summary` becomes the card's subtitle; the "Plan" title goes away.
Recipe-owned rows (highlight count and length, camera focus, B-roll, podcast
framing, target length and pacing) stay directly under the recipe. Replace
"Maximum highlights (0 = no limit)" with a picker offering No limit and a count.

Files: `WizardView.swift` (`configurationForm`), `ReelRecipe.swift`
(`menuSections`, `Capabilities`), `WizardFormPlan.swift`.

### 5. Brief placed under the recipe, labelled per recipe (C3, X4, X6)

The text box moves below the recipe in From footage mode and stays first in From
an idea mode. Its placeholder and caption come from the recipe:

| Recipe | Placeholder |
| --- | --- |
| Custom | Describe the outcome, hook, or must-have moments |
| MMA finish, exchange, submission, technique | The hook or must-have moment |
| Podcast highlights | Rules for choosing highlights |
| Interview, podcast | What the reel should say |

`referenceTemplateChip` moves beside the brief, since it guides the outcome.

Files: `WizardView.swift`, `ReelRecipe.swift` (a `briefPrompt` per recipe),
`WizardFieldHelp`.

### 6. Editing and appearance in one disclosure (X6, C9)

After Sources and Outcome, a `DisclosureGroup("Editing and appearance")` holds
framing, B-roll (toggle visible, custom instructions disclosed separately), audio
and music folder, on-screen text and caption language, quality, review proposed
cuts, layouts, bumpers, branding and style reference, gated by the existing
capability flags. The collapsed label carries a summary such as "Mix · Captions ·
Best of 3 · Brand default".

Rows a recipe does not support show as a single caption inside the group, "Not
used by Podcast highlights: captions, music, branding", instead of vanishing.

Files: `WizardView.swift` (`configurationForm`), `WizardPodcastControls.swift`,
`WizardFormPlan.swift` (the summary and the unsupported list).

### 7. Models demoted into a collapsed AI settings group (C5, X7)

Remove the `Section("Models")`. A `DisclosureGroup("AI settings")` after Editing
holds `TaskModelPickers` and the Model override field together, with a caption
that separates the two scopes: routing rows are shared defaults saved to Settings,
the override applies to this run only. The collapsed label shows the routed
provider and model for the recipe's primary task. Provider failures that block
generation still surface in the readiness line of item 2.

Files: `WizardView.swift`, `TaskModelPickers.swift`.

### 8. Show the effective run (X8)

Bind pacing and render controls to a resolved run configuration rather than to
`activeProfile` directly. A small badge on each row reads "Profile default" or
"Copied override"; editing changes this run, and a "Save as default" button in the
row writes back to the profile. Every active pasted source restriction appears in
the Sources card as a removable chip, replacing the hidden "Use all available
sources" button under Copied advanced options.

Files: `WizardView.swift` (`configurationForm`, `runWizard`, `computeSourcePool`,
`sourceSummary`), `WizardPreferences.swift` (`WizardDefaults`).

### 9. Primary action named after what happens next, with a summary (C7, X9)

The generation bar keeps its position. The button reads **Find highlights**,
**Prepare cuts** or **Generate reel** depending on the resolved configuration
(`WizardFormPlan.primaryActionTitle`). Above it, one sentence composed from view
state: "5 highlights, up to 30s each, from Modestino Podcast 02.mp4, reviewed
before render" or "One 20s reel from 24 scenes of Jack Della Maddalena, captions
on, best of 3". Build manually stays secondary.

Files: `WizardView.swift` (`generationBar`, `startGeneration`),
`WizardFormPlan.swift`.

### 10. Toolbar trimmed to the Wizard's own actions (C8)

Content Gaps and Manage Learned Rules are profile-level tools. Move them to the AI
Lessons resource screen, where learned rules already live. Keep Training Guide and
the paste-settings bar. This follows the existing toolbar convention: actions as
buttons, no More menus.

Files: `WizardView.swift` (`toolbar`), `LearnedPreferencesView.swift`.

## Resulting form order

1. Entry mode (From footage / From an idea), hidden when arriving from a handoff
2. Sources card with readiness
3. Outcome: one reel or highlights, recipe, recipe-owned rows, brief
4. Editing and appearance (collapsed)
5. AI settings (collapsed)
6. Summary line and primary action (pinned bottom bar)

## Phasing

- **Phase 1, correctness.** Items 1 and 8. Small, testable, no layout change.
- **Phase 2, structure.** Items 2, 4, 5, 9. The form's new skeleton; most of the
  visible change.
- **Phase 3, entry paths.** Item 3. Depends on the Sources card from phase 2.
- **Phase 4, cleanup.** Items 6, 7, 10.

Each phase is one Codex pass followed by a Claude build-for-testing, the affected
test suites (`WizardEngineTests`, `WizardRequestParserTests`,
`PodcastHighlightFinderTests`, `ReelRecipeTests`, `WizardFieldHelpTests`, plus a
new `WizardFormPlanTests` for readiness, summaries and the action title) and a
run of the app on the Peace Grappler profile to check the layout in the 360pt
minimum width.

## Resolved decisions

1. From an idea proposes footage only, never a recipe. The existing generate-request
   job parses the brief and searches scene metadata; the form shows the proposal
   and requires a second action before planning.
2. AI settings summarizes task `wizard` for scene recipes and `highlights` for
   Podcast highlights.
3. Content Gaps and Manage Learned Rules live on AI Lessons
   (`LearnedPreferencesView.swift`).

## Verification handoff

All four phases and all ten items have concrete changes. No build, tests, or app
run were performed in the Codex sandbox. Claude must build-for-testing, run the
named affected suites (including `PodcastHighlightIntegrationTests`), and check
Peace Grappler at 360pt. The original AppStorage keys and source-picker bindings
are preserved; the protected People work and registries were not edited.

## Addendum, September 29, 2026: the iterate-until-approved outcome

Approved by the user after 1.90 shipped. Depends on `docs/Critic-Brief-Plan.md`
phases 1–3 landing first, so the critic that drives retries is grounded in the
owner's own reels. Implementation: Codex; build, tests and review: Claude.

### 11. "Iterate until the critic approves" as an Outcome

The critique loop already exists (`WizardEngine` render → `ReelCritic` →
re-plan with `WizardPlanRules.critiqueFeedbackBlock`, up to 3 versions) but is
hidden as the Quality picker inside Editing and appearance, with the pass mark
(85) and the cap (3) hard-coded in `ReelCritic.swift` and `WizardEngine.swift`.

- `ReelRecipe.Workflow` gains `.iterate` ("Create one reel, iterate until
  approved"). It is not a recipe property: every `.oneReel` recipe is valid
  under it. `menuSections(workflow:preferredSources:)` treats `.iterate` as
  `.oneReel` for recipe filtering; `ReelRecipe.workflow` stays `.oneReel` for
  those recipes and the form tracks the chosen outcome in
  `@AppStorage("wizard.outcome")` ("oneReel" | "iterate" | "highlights").
- Choosing `.iterate` sets `critiqueLoop = true`; choosing `.oneReel` sets it
  false. The Quality picker is removed; its help text moves to the outcome row.
- Two new run options on `WizardOptions` (and `AIRunSettings` copy keys):
  `critiqueTargetScore: Int = 85` and `critiqueMaxVersions: Int = 3`. Shown
  directly under the Outcome picker only when `.iterate` is chosen: a "Target
  score" stepper (60…95, step 5) and an "Attempts" stepper (2…5). Persisted in
  `@AppStorage("wizard.critiqueTargetScore")` / `("wizard.critiqueMaxVersions")`.
- `ReelCritic` receives the target: the "regenerate only if score < 85" line in
  the prompt and the post-parse clamp (`if critique.score >= 85 { regenerate =
  false }`) use `options.critiqueTargetScore`. `WizardEngine` uses
  `options.critiqueMaxVersions` in place of the literal 3.
- The run summary line (item 9) reads "One 20s reel from 24 scenes, up to 4
  versions until the critic scores 80+". The primary action title stays
  "Generate reel".
- Every version keeps its critique as today. When the loop ends because the cap
  was reached, the log states the best score and which version holds it.

### 12. Best version pick and discard

When an iterate run finishes with more than one version, the results sheet
(`WizardResultsSheet`) marks the highest-scoring version "Best" (ties: the
latest) and offers "Keep best only", which deletes the other versions of the
same `batchID` through the existing generated-video delete path, with the
standard confirmation. Nothing is deleted automatically. `GeneratedVideoRecord`
needs no new column: "best" is derived from `critique.score` within the batch.

Tests: `WizardFormPlanTests` (outcome ↔ critiqueLoop mapping, summary text),
`ReelCriticPromptTests` (target score appears in the prompt and clamp),
`WizardEngineTests` (cap honored), a pure `WizardBatchRanking` helper test for
the best-version pick with ties.
