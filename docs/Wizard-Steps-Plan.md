# AI Wizard Steps

Date: October 10, 2026
Status: implemented October 11, 2026. Debug build passes; WizardStepFlow, MiniWizardFlow, WizardFormPlan, WizardSelectionRules and WizardFieldHelp tests pass. Real-footage hand checks still pending.

## Critique of the incumbent page

Method: independent assessments A (`design_assessment`) and B (`detector_assessment`).
Evidence: supplied empty-project screenshot and current SwiftUI source; the first,
real-footage attachment is missing. No app was launched. Operate mode: editors need
to prepare footage, save moments and render a chosen take with a reusable look.

| Nielsen heuristic | Score / 4 | Finding |
| --- | --- | --- |
| System status | 2 | Run status exists, configuration progress does not. |
| Match to real work | 3 | Good editing vocabulary, too many competing workflow terms. |
| Control and freedom | 3 | Cancellation and reusable answers work; revisiting is laborious. |
| Consistency | 2 | Express has steps; this page has an undifferentiated form. “Render” has two meanings. |
| Error prevention | 3 | Good readiness checks; prerequisites are visually unclear. |
| Recognition over recall | 2 | Source, take and look must be mentally carried between distant rows. |
| Efficiency | 3 | Powerful customization and paste support; slow scanning. |
| Minimalist design | 1 | Continuous row rules give nearly everything equal weight. |
| Error recovery | 3 | Useful recovery actions, not exercised at runtime in this review. |
| Help | 3 | Useful tooltips/captions compete with the main sequence. |
| **Total** | **25 / 40** | Significant improvements needed. |

P1: split the oversized first engine phase into human decisions; distinguish selecting
an existing take from rendering it; revalidate source requirements when recipe changes.
P2: expose Look as a named step with subgroups; reduce the visual noise and eye travel
of the full-width row grid. Strengths retained: native controls, reusable selections
and takes, persistent action/summary strip, explicit resource recovery and cancellation.

Cognitive-load failures: single focus, chunking, hierarchy, one decision at a time,
working-memory burden and progressive disclosure. Native menus constrain individual
choices, but the first viewport presents more than four distinct decisions at once.
The empty state feels like many settings to complete before progress. The confidence
point should be the saved selection; Render should name the take and the look.
New users need sequence; returning editors need Change and direct selection reuse;
keyboard/VoiceOver users need native actions and textual prerequisites.

Detector: `impeccable detect --json ClipBuilder/Views/WizardView.swift` returned `[]`
(exit 0). It reports no Swift coverage metadata, so this is not native-layout proof.
Slug: `clipbuilder-views-wizardview-swift`; no ignore file. No browser DOM, overlay,
server or temporary capture applies to this native task. Critique is persisted here
with the shape brief as requested, rather than changing PRODUCT.md or DESIGN.md.
Questions skipped: the user's detailed implementation brief already settles scope,
Operate mode, visual authority, steps and delivery; no further approval is required.

## Shape and visual authority

Use Express's native, flat numbered cards, semantic colors, SF text and Theme spacing.
One open card carries the current decision. Collapsed cards retain a single answer
line and a visible Change action; unavailable cards explain their prerequisite.
Explicit Continue acknowledges defaults and optional answers without auto-collapsing
while a user edits. No new persisted settings or alternate engine path are needed.
Cards span the pane; adaptive label-leading/control-trailing rows can stack in narrow
panes. Use native controls, headings, focus and Reduce Motion-aware navigation.

## Sequence, content and collapsed summaries

| Step | Content and rationale | Collapsed answer |
| --- | --- | --- |
| 1 Start | Footage/idea entry (hidden for handoffs), Workflow, pasted-settings row with Clear, pending request banner. Establish the route. | `From footage · Automatic` / `From an idea · Review moments and look`, with paste/request status when relevant. |
| 2 Sources | Footage grid, selection count, filters, evidence, copied restrictions, framing/readiness and recovery. Idea input and Find footage proposal live here until matched footage can be confirmed. | `24 scenes · 3 videos · All analyzed scenes` or `1 recording · filename`; an empty/unmatched idea states what is missing. |
| 3 Outcome | Outcome, critic target/attempts/brief refresh, recipe/caption, highlight count/length or target duration; canvas/quality/safe area and Save as default. Output format belongs with what will be made. | `One reel · Custom · 20s · 9:16 · 1080p` (highlights includes count and maximum seconds). |
| 4 Brief & planning | Recipe-specific brief, template, copied planning details, research/learned rules, style reference, layouts, Planning AI settings disclosure. These influence discovery. | First nonempty brief line, or `Recipe guidance · Profile taste`; optional text never blocks footage entry. |
| 5 Find the moments | Existing Find action, busy status, saved selections with take count, review/open, Use selection and Delete. Current take anchor. | `Selection name · Take N · duration · N takes`, or `No saved selection yet`. |
| 6 Look | Sound/music; captions/name tags; overlays; pacing/transitions; camera/B-roll; bumpers; branding; presentation AI settings. This decorates a take. | Existing effective editing summary plus camera focus where applicable. |
| 7 Render | Named current selection/take, changed-footage recovery, Render action and look/output summary. Without a take, explain Automatic's generation action in the persistent strip. | Current take or `Generate a new reel with these settings`. |

B-roll stays in Look (not planning): the two-step engine treats it as presentation.
Shared output controls move together to Outcome, including custom dimensions, CRF,
platform targeting and the override-origin label; no controls are duplicated.

## Prerequisites and revisiting

- Start is initially open; a handoff acknowledges Start and opens Sources.
- Sources and Outcome become reachable after Start. Outcome remains reachable even
  with missing sources because choosing a recipe can change the required source kind.
- Sources completes only after a usable source exists and the user confirms it.
  Idea mode requires a completed proposal and explicit footage confirmation.
- Brief/planning needs confirmed Sources and Outcome. Find needs confirmed planning
  and the same readiness used by the existing generation action.
- A recipe/source change invalidates source confirmation; Outcome remains open while
  editing, then Continue returns to Sources if needed. Confirmation uses current
  filters, not a frozen copy of the scene pool.
- A saved project selection can be reopened directly from Find even if new-run
  setup is incomplete. Use selection opens Look; missing/changed footage blocks
  Render with the existing recovery instruction. Saved selections are never deleted
  or invalidated merely because the new-run inputs change.
- Review workflows need a saved take before Look/Render. Automatic may configure
  Look after planning without a saved take; its Find card offers Continue to look.
  This acknowledges the shortcut without claiming discovery has happened.
- Change overrides the automatic next-unanswered step only while its prerequisite
  holds. Removing an input clamps navigation. Project/profile changes reset local
  progress while preserving every existing persisted answer.
- `wizardLookRevision` opens Look after review acceptance. Pending request status
  remains visible in Start, and Stop remains usable during proposal work.

## Disclosure and deliberate omissions

Nothing is removed from the feature set. Planning/presentation model routing,
transition allowlists, copied planning details and B-roll instructions retain
explicit disclosures. Dependent rows/captions are indented with `formDependent()`.
No List or Form is nested in the scrolling cards. Remove unused WideFormStyle.
No new recipe, AI task, persistence migration, rendering/critic change or settings
key. The persistent generation strip, handoff logic and choice-refresh tasks remain.

## Implementation and verification

1. Add nonisolated WizardStepFlow with step order, confirmations, prerequisite
   messages, requestedStep override and answer summaries; add Swift Testing coverage.
2. Reuse MiniCard's surface for the numbered page; keep Express unchanged. Split
   WizardView into state/actions, Steps, Fields and Look extensions. Opt shared
   controls into adaptive card rows only within the full Wizard.
3. Audit existing control/tooltips/task handlers against the original source;
   run `git diff --check`, without compiling or executing tests.
4. Claude: build-for-testing, run the requested flow tests, capture light/dark,
   narrow/wide, empty/footage/idea/handoff/saved-take states. Check keyboard/VoiceOver,
   Change/Continue, source revalidation, automatic and both review workflows,
   stale takes, cancellation, pasted overrides and generation-strip reachability.

## Changed files and static checks

- `ClipBuilder/Views/WizardView.swift`: state/actions, stable lifecycle observers and persistent action strip.
- `ClipBuilder/Views/WizardView+Steps.swift`: seven cards, effective answers, Continue/Change and handoff navigation.
- `ClipBuilder/Views/WizardView+Fields.swift`: source, outcome, brief/planning, selection rows and request banner.
- `ClipBuilder/Views/WizardView+Look.swift`: presentation subgroups and dependent controls.
- `ClipBuilder/Services/Wizard/WizardStepFlow.swift`: pure navigation, prerequisites, completion and summaries.
- `ClipBuilderTests/Services/Wizard/WizardStepFlowTests.swift`: 15 tests listed below (not executed).
- `ClipBuilder/Views/MiniCard.swift`: optional Change and compact summary; Express call sites keep their defaults.
- `ClipBuilder/Views/WizardControlRow.swift`: opt-in adaptive rows for card content.
- `ClipBuilder/Views/RenderSettingsControls.swift`, `EditPacingControls.swift`, `TaskModelPickers.swift`: shared controls adopt card rows in the Wizard; platform choices can wrap as whole controls.
- `ClipBuilder/Views/WizardPodcastControls.swift`, `WizardCameraFocusPicker.swift`: row alignment and disclosure spacing.
- `ClipBuilder/Views/WizardSourceGrid.swift`: single-line counts and Reduce Motion support.
- `ClipBuilder/Views/WizardBrandingDefaultsSection.swift`: directs users to the Look step for a run override.
- `ClipBuilder/Data/WizardFieldHelp.swift`: removed the now-unused uncommitted WideFormStyle; file returns to its committed contents.
- This plan and ignored `HANDOFF.md`.

Static inspection confirmed all 51 AppStorage expressions/keys retained, every existing
fieldHelp expression retained, and `formOptions`, `presentationOptions`,
`computeSourcePool`, `startGeneration`, `findMoments`, and `runWizard` unchanged.
No Form/List remains in the Wizard page and no WideFormStyle usage remains.
`git diff --check` passes. No claim of compiled or runtime correctness is made.
Recipe, music, duration, transition and bumper observers live on the page so collapsed
cards cannot suspend their side effects. A pasted per-field edit does not reopen Start.

### WizardStepFlowTests

- `initialStepRequiresAcknowledgementEvenWithSavedDefaults`
- `nextUnansweredStepOpensInOrder`
- `outcomeCanRepairMissingSourcesWithoutSkippingPlanningPrerequisites`
- `continuingOutcomeRechecksSourcesAndThenReturnsToPlanning`
- `ideaNeedsAProposalAndExplicitSourceConfirmation`
- `changeOverridesProgressAndReturnsToNextUnansweredWhenCleared`
- `staleChangeRequestClampsWhenSourcesDisappear`
- `automaticCanConfigureLookBeforeDiscoveryWithoutClaimingASavedTake`
- `reviewWorkflowsRequireASavedTakeForLook`
- `savedSelectionsCanBeReusedWithoutNewRunSources`
- `deletedTakeClampsReviewFlowBackToDiscovery`
- `changedFootageAndBusyWorkBlockRenderingButKeepRecoveryReachable`
- `summariesReflectAnswersAndSingularCounts`
- `summariesCoverEmptySourcesRecordingsAndOptionalBrief`
- `exactlyOneStepIsOpenAcrossPrerequisiteCombinations`
