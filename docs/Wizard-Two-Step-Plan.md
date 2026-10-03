# Wizard Two-Step Plan

Date: October 2, 2026. Status: approved for implementation (Codex), reviewed by Claude.

## Problem

The AI Wizard asks every question up front and then runs one job that both
*chooses the footage* (AI, non-deterministic) and *dresses it* (captions,
overlays, transitions, camera focus, bumpers, branding — deterministic). A user
who wants to try a different look must re-run the planner and gets different
footage; a user who wants different footage waits through a full render each
time. The seam already exists in the code — `WizardEngine.plan` returns a
`WizardPlan`, `renderApprovedPlan` turns one into a reel, and the "Review
proposed cuts before rendering" toggle drives a wedge between them
(`AppStore+Wizard.swift`, `startWizard`) — but nothing persists between the two
halves, and the form does not know which questions belong to which half.

## Shape

Two steps, each with its own questions, its own button and its own saved result:

| Step | Name in the UI | Does | Deterministic |
| --- | --- | --- | --- |
| 1 | **Find the moments** | Planner picks scenes, in/out points, order, editorial text | No (AI) |
| 2 | **Make the reel** | Captions, overlays, transitions, camera focus, canvas, bumpers, branding, music, render | Yes |

The result of step 1 is a **Selection**: a saved, named, re-openable record with
a history of **takes**. The user iterates on takes until one is right, then
renders it as many ways as they like in step 2. Step 2 never calls the planner.

The one-button path stays: **Generate reel** runs step 1 with the saved step-1
answers and then step 2 with the saved step-2 answers, exactly as today. The
current "Review proposed cuts before rendering" toggle becomes a three-way
**Workflow** choice:

- **Automatic** — both steps, no stop (today's default behaviour).
- **Review the moments** — stop after step 1 in the Selection review; render on Accept.
- **Review moments and look** — stop after step 1, then stop again in step 2's
  panel before rendering.

## Which question belongs to which step

Step 1 asks only what changes *which footage* is chosen. Step 2 asks only what
changes *how it looks*. A question is never shown before the step it applies to.

**Step 1 — Find the moments** (`WizardOptions` fields in parentheses)

- Sources: videos, analyze batches, people, favorites only (`sourceSceneIDs`, `sourceVideoPaths`, `sourcesRestricted`, `selectedRunIDs`, `favoritesOnly`, `sourcePeople`)
- Outcome and Recipe (`formatPreset`, highlights vs one reel)
- Length / maximum highlights (`targetDurationSeconds`, `highlightMaxSeconds`, `highlightMaxCount`)
- What the reel should say / brief (`aiInstructions`, `pinnedOverlayText`)
- Style reference and fight research (`tastePreset`, `useFightResearch`)
- Layouts the planner may fill (`screenCropLayouts`) — the planner chooses which *scenes* share a frame, so this is selection
- Iterate until approved: target score, attempts (`critiqueLoop`, `critiqueTargetScore`, `critiqueMaxVersions`) — the critic judges *content* here, on the proxy render
- Model routing for planning and critique (`modelOverride`, routing rows)

**Step 2 — Make the reel**

- Canvas, platform safe area, encode quality (`renderSettings`)
- Cut cadence and pace curve (`pacing`) — applied as deterministic trims/snaps to the selection, see "Pacing" below
- Audio: original / original + music / music only, music folder, **track** (`useMusic`, `muteSource`, `musicFolder`, new `musicTrack`)
- On-screen text: captions, headlines, both, none; caption language (`addCaptions`, `enableTextOverlays`, `captionLanguage`)
- Overlay style: template or preset style, animation, placement (`pinnedOverlayTemplate`, new `overlayStyle`, `overlayAnimation`, `overlayPlacement` — today the planner invents these per clip)
- Transitions: allowed list (`allowedTransitions`)
- Camera focus (`highlightFraming`, `podcastFraming`) and framing camera (`framingCamera`)
- B-roll and its instructions (`useBRoll`, `brollInstructions`) — B-roll placement is an AI call today but it dresses a chosen cut, so it belongs here and runs inside step 2
- Bumpers (`includeIntroBumper`, `includeOutroBumper`, `includeMiddleBumper`)
- Branding (`includeWatermark`, `includeHeadline`, `includeOutro`)
- Model routing for captions and B-roll

Remove from the form: nothing is lost; every control moves to its step. The
"Editing and appearance" disclosure becomes step 2's panel. "AI settings"
splits: planning and critique rows under step 1, caption and B-roll rows under
step 2 (`TaskModelPickers(tasks:)` already takes a task list).

## Step 1: the planner on a diet

`WizardPlan` today carries presentation the planner should not decide. After
this plan it carries selection and editorial text only:

| Keep in `WizardPlan` | Why |
| --- | --- |
| `clips[].sceneID/start/end`, order | the selection |
| `clips[].reason` | shown in review |
| `clips[].speed`, `replay` | a slow-motion replay is a content decision |
| `clips[].layout`, `areaClips` | which scenes share the frame |
| `clips[].textOverlay` (the words only), `headline`, `introTitle`, `fileName`, `rationale` | editorial text; step 2 decides whether and how it shows |
| `clips[].speakerIntroductions`, `leftSpeakerName`, `rightSpeakerName` | names come from analysis, not style |
| `framing` (podcast) | a suggestion; step 2's Camera focus "Let AI choose" reads it |
| `provenance` | AI details |

| Move out | Goes to |
| --- | --- |
| `musicName`, `musicVolume` | step 2 `musicTrack` (deterministic pick: the user's chosen track, else the first track in the chosen folder that fits the length, else none). Volume = profile default. |
| `transitions[]` | step 2: `cut` everywhere, then the allowed-transitions rule in `WizardPlanRules` (a pure function: allowed list + pacing → per-boundary name). |
| `overlayStyle`, `overlayAnimation`, `overlayKicker`, `overlayAccent`, `overlayPlacement`, `overlayCase` | step 2 overlay style, one choice for the whole reel. `kicker` stays as text if the planner writes one. |

Prompt changes (`WizardEngine.planPrompt`): drop the music list, the beat
paragraph, the transition list, and the six overlay-style fields from the JSON
schema and the RULES block. `validatePlan` stops reading them. Fewer fields,
shorter prompt, more stable plans. The `AIRunSettings` snapshot keeps every
field (Codable, additive) so old provenance still decodes.

Pacing: `EditPacing` (cut cadence, pace curve) is used by the planner today as
target clip lengths. It stays a planner hint in step 1's prompt *and* a
deterministic trimmer in step 2 (`WizardPlanRules.applyPacing(plan:pacing:)`:
shorten clips toward the cadence from the end that the planner marked least
important — the `reason` order — never below 1.5 s). Step 1 shows no pacing
controls; step 2 does.

## The Selection record

New table (`Database.swift`, additive migration):

```sql
CREATE TABLE IF NOT EXISTS wizard_selections (
    id INTEGER PRIMARY KEY,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,                 -- planner headline or "Selection N"
    recipe TEXT NOT NULL,               -- formatPreset
    step1_options_json TEXT NOT NULL,   -- the step-1 subset of WizardOptions
    best_take_id INTEGER,               -- the take the user accepted (or critic's best)
    created_at TEXT DEFAULT (datetime('now')),
    edited_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS wizard_selection_takes (
    id INTEGER PRIMARY KEY,
    selection_id INTEGER NOT NULL REFERENCES wizard_selections(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,           -- 1, 2, 3 …
    note TEXT,                          -- what the user asked for in this take
    plan_json TEXT NOT NULL,            -- WizardPlan (Codable, see below)
    scene_ids_json TEXT NOT NULL,       -- for "scene removed" invalidation
    proxy_path TEXT,                    -- small render for review, cache folder
    critic_score INTEGER,
    critic_notes TEXT,
    provenance_json TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);
```

`WizardPlan` and `WizardPlanClip` gain `Codable` (synthesized; every new
property Optional). Queries live in `Data/Database+WizardSelections.swift`.
`generated_videos` gets a nullable `selection_take_id` column so Outputs can
show which take a reel came from, and `timelines.source_run_id` is reused for
Builder handoffs (`"take:<id>"`).

A take whose scenes were deleted or re-analyzed (scene ids are per-process
random after `saveAnalysis`; compare by video + time range, not id) shows
"Footage changed" and can be re-planned but not rendered.

## Step 1 UI: the Selection review

Reuse `ProposedCutsSheet` (player, draggable trims, Space / I / O) as the body;
add around it:

- Left: the **takes** list (`Take 1 · 24 s · 4 cuts`, the note under it, critic
  score when present, ★ on the best). Selecting a take shows its cuts.
- Top: the Selection name (editable), the recipe and length as text, and the
  planner's `rationale` in one caption line.
- Bottom bar: **Another take** (text field for the note + button; sends the
  note as a planner rule the way critic notes feed re-planning today),
  **Accept** (marks best, closes, continues per Workflow), **Open in Builder**
  (existing handoff), **Keep for later** (closes, nothing runs).
- Trims the user drags are saved into the take (a new take ordinal is *not*
  created; the plan on the take is updated — the user's hand edit is part of
  that take).

Long work never runs inside the sheet: **Another take** dismisses it, the
planner runs through the existing wizard status (status bar row with Stop,
`isWizardRunning`), and the sheet reopens on the new take. Same for proxy
renders. See `docs/Async-AI-Actions-Plan.md`.

Where it opens from: the Wizard page's step 1 card, the Outputs list ("Reel
from Take 2" → opens the selection), and a new **Selections** row in the Wizard
page listing saved selections for the project (name, takes, last edit, Render
button straight into step 2).

## Step 2 UI: Make the reel

The current "Editing and appearance" disclosure, rewritten as a card headed
**Make the reel** with the selection it will render named at the top
("From *Guard pass that ended it* · Take 2 · 24 s"). Grouping from the October 2
layout fix stands: Output / Sound and text / Planning → renamed **Pacing and
transitions** / Bumpers / Branding, plus **Camera focus** moves here from the
main form for every recipe that offers it.

Buttons: **Render** (step 2 only, from the named take), and when no selection
exists yet the card shows "Find the moments first" with the step 1 button.
Rendering several looks from one take is normal; each lands in Outputs with
its `selection_take_id`.

`renderApprovedPlan` is the entry point; it loses its `critiqueLoop` branch
(the content critic runs in step 1) and gains the deterministic music,
transition and overlay-style application before `assemble`. The existing
rendered-reel critic keeps running after a step 2 render when **Critique
renders** is on, but it only *scores and notes*; it does not re-plan.

## Automatic path

`startWizard` with Workflow = Automatic: plan → create Selection + Take 1 →
proxy only if the critic loop is on → render through step 2 with the saved
step-2 answers. Nothing is shown until the Results sheet. The critic's iterate
loop (`runThrowing(initialPlan:)` attempts) produces takes 1…N on the same
selection; "Keep best only" deletes the other takes' proxies, not the records.

## Wizard page layout

```
┌ Start with  [From footage] [From an idea]            Workflow [Automatic ▾] ┐
│                                                                             │
│ 1  Find the moments                                                         │
│    Sources · Outcome · Recipe · Length · What the reel should say ·         │
│    Style reference · Layouts · Iterate until approved · Planning model      │
│    [Find the moments]                              Selections (3) ▸         │
│                                                                             │
│ 2  Make the reel                      From "Guard pass…" · Take 2 · 24 s    │
│    Output · Sound and text · Pacing and transitions · Camera focus ·        │
│    Bumpers · Branding · Caption model                                       │
│    [Render]                                                                 │
│                                                                             │
│ [Generate reel]  (both steps, Automatic)                 [Build manually…]  │
└─────────────────────────────────────────────────────────────────────────────┘
```

Rules for the form (`WizardFormPlan` decides visibility, as today):

- A control appears only in its step's card. No control appears twice.
- Step 2's card is collapsed (summary line only) until a selection exists in
  the project or Workflow is Automatic; then it expands on demand.
- Podcast highlights keep their own first step (`findPodcastHighlights` → the
  highlights review) and share step 2 unchanged.
- "From an idea" is a step 1 input (it produces the source selection), not a
  separate mode after this plan.
- The run summary line under the page names both steps: "Find: one reel from
  41 scenes, 25 s · Make: captions, Standard branding, Talker and rotating others".

## Phases

Each phase builds, passes its suites, and leaves the app usable.

**P1 — Model and persistence (pure + DB).** `WizardPlan`/`WizardPlanClip`
Codable; `wizard_selections`, `wizard_selection_takes`, `generated_videos.selection_take_id`;
`Database+WizardSelections.swift` (insert selection, add take, update take plan,
set best, list by project, delete); `WizardOptions.step1`/`.step2` split
(`Data/WizardOptionsSteps.swift`, pure: two Codable subsets plus `merge`).
Tests: `WizardSelectionStoreTests`, `WizardOptionsStepsTests`, `WizardPlanCodableTests`.

**P2 — Engine split.** `WizardEngine.findMoments(options:note:previousTakes:)`
returns `(plan, sceneMap)` and records a take; `WizardEngine.makeReel(take:options:)`
= `renderApprovedPlan` minus the critique branch plus the deterministic
`WizardPlanRules.applyPacing`, `.transitions(allowed:count:)`, `.musicTrack(folder:tracks:duration:)`,
`.overlayStyle(plan:style:)`. `run` (Automatic) composes the two. Planner prompt
diet and `validatePlan` cleanup. Tests: `WizardPlanRulesTests` (new rules),
`WizardEngineTests` (prompt no longer lists music/transitions/overlay fields;
Automatic path produces a selection with one take).

**P3 — Selection review.** `Views/WizardSelectionReviewSheet.swift` wrapping
`ProposedCutsSheet`'s body with the takes list and bottom bar; `AppStore+WizardSelections.swift`
(open, another take, accept, keep, delete; reopen after a take lands). Status
bar and Stop through the existing wizard status. Tests: pure helpers for take
labels, invalidation by changed footage (`WizardSelectionRulesTests`).

**P4 — Wizard page.** `WizardView` restructured into the two cards and the
Workflow picker; `WizardFormPlan` gains `step1Controls`/`step2Controls`
(pure, tested in `WizardFormPlanTests`); `wizardOptionsFromForm` builds the
two subsets; `AnalyzeWizardSheet` (pipeline) uses the same subsets. Selections
row with Render. Outputs shows "Take N" and opens the selection.

**P5 — Critic split.** Step 1 critic on the proxy with the content rubric
(`ReelCritic` gets a `scope: .content | .presentation` that filters its rubric
and prompt); step 2 critic scores only. Iterate loop records takes. Tests:
`ReelCriticPromptTests` for both scopes.

**P6 — Cleanup.** Remove `reviewProposedCuts` (migrate to Workflow), remove the
planner's overlay-style parsing, remove `pendingCutReview` in favour of the
selection sheet, update `docs/Builder-Scripting-Reference.md` if script
commands expose the new names.

## Out of scope

- A second timeline editor. Anything beyond trims and the step 2 controls is
  "Open in Builder".
- Changing analysis, speaker mapping, or the podcast highlight finder.
- Sharing selections across projects or profiles.

## Acceptance

1. With Workflow = Automatic, **Generate reel** behaves as before: one job, one
   reel, Results sheet. Outputs shows "Take 1".
2. With Workflow = Review the moments: **Find the moments** opens the review
   with Take 1; **Another take** with "start on the answer" produces Take 2
   without a render; **Accept** renders Take 2 with the saved look.
3. From the Selections row, Render twice with different captions/branding
   produces two reels from the same take with no planner call (log shows no
   "Phase 2: Planning").
4. The planner prompt contains no music list, transition list or overlay style
   fields; plans decode from the stored JSON; old `AIRunSettings` decode.
5. No control is visible in both cards; step 2's card is collapsed until a
   selection exists or Workflow is Automatic.
6. Old defaults: a user who had "Review proposed cuts" on gets Workflow =
   Review the moments after launch (one-time mapping in `WizardPreferences.migrateLegacy`).
7. Podcast highlights still open their own review and render through step 2.
