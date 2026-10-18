# AI Wizard Parity Plan

Date: October 17, 2026. Status: phases 1–6 implemented October 17, 2026 (uncommitted at
the time of writing), with the deviations listed at the end. Debug build clean; the
suites named per phase pass. Builds on `docs/AI-Wizard-Mini-Plan.md`,
`docs/Wizard-Steps-Plan.md` and `docs/Express-Transcript-Picks-Plan.md`.

## Goal

The AI Wizard becomes the detailed, customizable version of AI Wizard Express:
the same page behaviour (free card navigation, inline footage review, per-profile
remembered settings with named presets, batch generation with the captions and
timings work of 1.106), plus everything Express deliberately leaves out
(recipes, outcome and critique, briefs and planning preferences, source filters,
music, text modes, overlays, pacing, B-roll, branding, takes and selections).
A user who knows Express should recognise every card; a user who needs control
should never have to leave the Wizard for it.

## Where the two pages differ today

Read from `MiniWizardView`, `MiniWizardFlow`, `MiniSettingsCard`,
`MiniFootageCard`, `AppStore+MiniWizard` against `WizardView` (+Steps, +Fields,
+Look), `WizardStepFlow`, `WizardSelectionReviewSheet`, `AppStore+Wizard`.

| Behaviour | Express | AI Wizard today |
| --- | --- | --- |
| Page structure | 3 cards: Source, Footage, Settings | 7 cards: Start, Sources, Outcome, Brief & planning, Find the moments, Look, Render |
| Navigation | Any header opens at any time; a card without its inputs says what to do first (`MiniWizardFlow.canExpand` only changes the body) | Gated: `prerequisite(for:)` blocks headers, `confirmedSteps` + "Continue to …" buttons, a `Change` affordance, auto-scroll to the open step |
| Footage kinds | Q&A, Transcript (no AI, auto-load when the card opens), Highlights (instructions + Generate footage + model button) | From footage / from an idea; "Find the moments" runs the planner; no Q&A or Transcript picks |
| Footage review | Inline on the page: `RangeReviewView` with player, draggable start/end, kept toggles, Reset to Suggested, per-item regenerate | Modal `WizardSelectionReviewSheet` (takes list + `ProposedCutsEditor`); a Selections list on the Moments card with Use / Delete |
| Settings storage | `MiniWizardSettings` struct, remembered per profile (`MiniWizardMemory` key catalog), Codable with `decodeIfPresent` | About 45 `@AppStorage` keys, app-wide, not per profile; two "Save as default" buttons write profile defaults |
| Presets | Save… / Load… on the card header; stored on `BrandProfile.expressPresets`; shared by Team Sync; card title names the loaded preset and flags edits | None |
| Settings on the card | Quality, Canvas, Camera focus, Captions (+ English captions), Caption position/style, Name tags (content/style/position), Watermark (overlay template + opacity), Overlay (template, start, duration, texts), Intro/Outro video with per-slot bumper, Transition at every cut, Look, Output mode | Audio mode, music folder/track, on-screen text mode, caption position/style/language, name tags, overlay template/style/animation/placement, pacing, limit transitions + allowed list, camera focus + framing camera, B-roll + instructions, intro/outro/middle bumpers (no per-slot choice), branding override, output format + quality, strike stats |
| Generation | Batch of kept items as separate videos or one reel; `WizardReelBatch` with captions requested at Generate, traits and report in the deferred finish, "Writing N captions" status, `Timings ·` summary lines | One take rendered inline through `renderWizardSelection`; Automatic workflow finds and renders in one run; no batch, no prefetch, no timings summary |
| Model routing | `MiniModelButton` beside each AI step | Model override field under planning; AI setup readiness warnings |
| Long work | `wizardTask` + status bar + Stop (same as the Wizard) | Same |

Everything in the right column that Express lacks is a feature to keep, not a
pattern to remove.

## Target page

Four cards, numbered, in `MiniCard`, with the Express header behaviour:

1. **Source** — the project's analyzed videos (grid, as Express) plus the
   Wizard's filters as an "Advanced" disclosure: Analyze runs, people, favorites
   only, limit to selection, stack level, and the "from an idea" entry (brief
   first, then Find footage). Podcast-recording recipes pick one recording here.
2. **Plan** — Outcome (one reel / variations / critique loop with target score
   and attempts), Recipe, Length, Output format, Brief, Planning preferences
   (fight research, style reference, layouts, model override). Everything that
   shapes what the planner is asked for and nothing about how it looks.
3. **Footage** — footage kind as Express (Q&A, Transcript, Highlights; Highlights
   runs the planner with the Plan card's brief) and the inline review: takes as
   rows of `RangeReviewView` with watch and drag, kept toggles, per-item
   regenerate, Reset to Suggested, selection rename, and the saved Selections
   list for returning to earlier runs. The user rule holds: anywhere a cut is
   reviewed, it can be watched and its start and end dragged.
4. **Settings** — the full Look in Express order with groups: Picture (quality,
   canvas, camera focus, framing camera, look + intensity), Cuts (transition at
   every cut, pacing, allowed transitions), Text (captions on/off, language,
   position, style, name tags, on-screen text mode), Overlays (template, style,
   animation, placement, fixed Express overlay with start/duration/texts,
   watermark overlay + opacity, branding), Structure (intro/outro/middle bumpers
   with per-slot choice, B-roll + instructions), Sound (audio mode, music
   folder, track), Output mode (separate videos / one reel), Strike stats for
   fight recipes. Save… / Load… presets on the header; card title names the
   loaded preset.

The generation bar stays pinned at the bottom (Generate Video(s) / Render /
Stop, summary line) as both pages have it today.

## Phases

### Phase 1 — Free navigation and four cards (behaviour parity)

- New `WizardCardFlow` (pure, `nonisolated`, in Services/Wizard) modelled on
  `MiniWizardFlow`: `Card` enum of four, `canExpand` only decides whether the
  body shows controls or a one-line "do X first" caption, `openCard` is the
  requested card, header click toggles, summaries per card. `WizardStepFlow`
  is retired with its `confirmedSteps`, `Continue to …` buttons and
  `prerequisite(for:)` gating.
- `WizardView+Steps` rebuilt around the four cards; `+Fields` and `+Look`
  content regrouped into the cards above without changing their bindings yet.
- Card summaries reuse the existing answer strings (`editingSummary`,
  `sourceSummary`, run summary) through one `WizardCardFlow.summary(for:)`.
- Tests: `WizardCardFlowTests` mirroring `MiniWizardFlowTests` (any card
  opens, bodies explain prerequisites, header toggle, summaries).
  `WizardStepFlowTests` removed with the type.

### Phase 2 — One settings struct per profile, presets, Team Sync

- `WizardSettings` (Codable, every key `decodeIfPresent`, like
  `MiniWizardSettings`) holding every Look and Plan answer that is presentation
  or planning preference. Source filters stay session/project state.
- `WizardMemory` key catalog (`wizard.<profile>.<field>`) with `remembered(profile:)`
  and `remember(profileName:)`; one-time migration that reads the legacy
  `wizard.*` AppStorage keys into the active profile's memory and then ignores
  them.
- `step1Options(base:)` / `step2Options(base:)` mapping to `WizardOptions`, with
  a test per field group as `MiniWizardSettingsTests` has.
- Presets: `BrandProfile.wizardPresets` (new optional key `wizard_presets`,
  added to `TeamProfileDocument.keys`; it rides inside the profile document, so
  no server `schema_version` change), `WizardPresetStore` generalised from
  `MiniWizardPresetStore` (or the Mini store made generic over the settings
  type), the existing Save / Load sheets reused with a settings-type parameter.
  Card title and edit flag as Express.
- "Save as default" buttons go: a preset named by the user replaces them, and
  profile editing defaults remain the fallback for a fresh profile.

### Phase 3 — Inline footage review and footage kinds

- The Footage card hosts `RangeReviewView` directly (as `MiniFootageCard`
  does), fed by the Wizard's selection takes through a `WizardFootageReview`
  adapter (the `MiniHighlightReview` rules generalised: items from takes,
  trimming back to a plan, kept IDs). Multiple takes per selection appear as
  rows under one selection group; the selected take plays.
- Q&A and Transcript footage kinds join the Wizard for podcast/interview and
  transcribed sources, reusing `AppStore+MiniTranscript` and the Q&A sections
  (shared store code moves out of the Mini-named files into
  `AppStore+WizardFootage`). They auto-load when the card opens, as Express.
- `WizardSelectionReviewSheet` is removed once the inline review covers rename,
  take choice, trim and regenerate. `ProposedCutsEditor` stays available from
  the Builder handoff only.
- Tests: adapter rules (items, trimming, kept), and the integration test that
  keeps a trimmed take rendering the trimmed range.

### Phase 4 — Generation parity

- Kept items generate as a batch through `WizardReelBatch` with
  `startCaptionRequests` at Generate time, deferred finish, "Writing N
  captions" status and the `Timings ·` summary, exactly as
  `generateMiniVideos`; the Mini-specific loop becomes the shared
  `AppStore.generateWizardBatch(takes:options:)` that both pages call.
- Output mode (separate videos / one reel) on the Settings card; one reel uses
  `recordMiniCombinedTake` generalised.
- Critique loop keeps working per reel inside the finish (already there).
- `MiniModelButton` placed beside each AI step on the Wizard: planner
  (wizard/highlights), captions, critique, framing, B-roll.

### Phase 5 — Settings parity plus the Wizard's extras

- Bring into the Wizard what only Express has: transition at every cut,
  fixed overlay with start/duration/texts, watermark overlay + opacity, per-slot
  bumper choice, Look picker (with an intensity slider, which Express does not
  offer), caption language auto-detection from the transcript.
- Keep and regroup what only the Wizard has (music, text modes, caption style,
  overlay style/animation/placement, pacing, allowed transitions, framing
  camera, B-roll, middle bumper, branding override, critique, strike stats,
  style reference, layouts, model override).
- One shared `WizardSummary` builder produces the Settings card summary for
  both pages so wording never drifts.

### Phase 6 — Express as a profile of the Wizard

- `MiniWizardSettings` becomes a projection of `WizardSettings` (the subset
  Express shows), so a preset saved in either page loads in the other with the
  hidden fields at their defaults. `expressPresets` migrate into
  `wizardPresets` with an `express` flag; the Team Sync document carries one
  key.
- Shared card components (`MiniCard`, `MiniRow`, preset sheets, model button,
  footage card) drop the `Mini` prefix.

Phases 1–4 deliver the behaviour parity the request asks for; 5 completes the
control set; 6 is the cleanup that stops the two pages from drifting apart
again.

## Rules carried over

- Every control visible on a card; no context-menu-only entry points.
- Long work through `wizardTask` or `AppJobs` with the status bar and Stop,
  never in a sheet.
- Reviewed cuts can be watched and dragged (user rule, October 2).
- No AI calls for item labels in review rows; nothing autoplays.
- New stored properties optional or `decodeIfPresent`; `WizardOptions` keeps its
  hand-written decoder.
- Toolbar and row text `lineLimit(1)` + `fixedSize` or `ViewThatFits`.
- No Supabase `schema_version` bump: presets live inside the profile document.

## Risks

- **AppStorage migration.** The 45 app-wide keys become per-profile values. The
  one-time import must be idempotent and must not clobber a profile that
  already has remembered values; a test covers a fresh profile, a migrated one
  and a second launch.
- **Selections and takes model.** The inline review must keep the existing
  `wizard_selections` / takes tables and `WizardSelectionRules`; nothing about
  storage changes, only the surface.
- **Handoffs.** Builder, Instagram template and "Open in Wizard" handoffs set
  `enteredWithHandoff`, `proposedSceneIDs` and recipe; each needs a card to land
  on (Source or Footage) and a test.
- **Critique and Review workflow.** The "pause for review" workflow becomes
  implicit: the Footage card is the review. The Automatic workflow remains as
  "Generate" from Settings without visiting Footage; the Workflow picker goes.
- **Size.** `WizardView.swift` is 1,263 lines plus 900 in extensions. Each phase
  should leave the files with a current `// MAP`.

## Verification per phase

Debug `build-for-testing`; the suites named in each phase run through
`scripts/release.sh` before any release. Hand checks on real footage for the
inline review (watch, drag, keep, regenerate), presets (save, load, rename,
delete, Team Sync round trip on a second Mac), and a batch generate with
captions on and the Look set.

## What shipped and where it deviates (October 17, 2026)

- **Phase 1.** `WizardCardFlow` with four cards; `WizardStepFlow` removed. The
  handoffs land on Source; "Use selection" lands on Settings.
- **Phase 2.** The answers stayed in the `wizard.*` defaults because the pipeline,
  the paste bar and resource bundles read them. `WizardMemory` snapshots them per
  profile (`wizard.<profile>.answers`) and restores them on profile switch; an
  install migrates in place. Presets are preset-shaped dictionaries (the paste
  bar's shape minus source and run fields), stored on `BrandProfile.wizardPresets`
  (`wizard_presets`, merged by name in Team Sync). Loading writes the defaults
  without a "Pasted from" snapshot. The two "Save as default" buttons stayed:
  they feed profile defaults other features use.
- **Phase 3.** `WizardFootageReview` + `WizardFootageReviewView` review takes
  inline (watch, drag, keep = best take, another take with a note, rename,
  delete). The review sheet still exists for Outputs' "open selection" and the
  Automatic workflow's accept path; the Wizard page no longer opens it. Q&A and
  Transcript footage kinds were **not** brought into the Wizard: they are per-video
  (the Express run model), while the Wizard's sources are multi-video pools.
  Express remains the place for them.
- **Phase 4.** `AppStore.generateWizardBatch` is the shared render (both pages call
  it); the Wizard's Generate renders every selection with a best take, separate
  videos or one reel (`recordCombinedWizardTake`), with a model button beside Find
  the moments.
- **Phase 5.** `WizardExpressExtras` reads transition at every cut, look and
  strength, fixed overlay (design, texts, start, duration), watermark design and
  opacity, and per-slot bumpers from the Wizard's defaults into `WizardOptions`,
  for the page, the pipeline and Outputs. New `WizardOptions.lookIntensity`.
- **Phase 6.** `WizardPresetBridge` maps Express settings to and from the Wizard's
  preset dictionaries; each Load sheet lists the other page's presets as load-only
  imports. Express's list rules delegate to `NamedPresets`. Express presets were
  not merged into `wizardPresets` (both keys stay), and the `Mini` prefixes were
  not renamed: pure churn with no behaviour change.
- **Not yet verified live:** the four-card page, the inline review and the batch
  Generate in the running app; a Team Sync round trip of `wizard_presets`.
